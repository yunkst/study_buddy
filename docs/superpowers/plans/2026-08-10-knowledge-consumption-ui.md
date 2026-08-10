# 消费侧 UI — 浏览 / 搜索 / 背诵(间隔重复) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 study_buddy 建立消费侧闭环——三 Tab 导航下的知识树浏览、关键词搜索、以及基于简化 SM-2 间隔重复的背诵复习。

**Architecture:** engine(`study_engine`)新增 `review_schedule` 表(v3 迁移)+ 纯函数调度器 `SpacedRepetitionService` + 两个背诵队列仓库;App(`study_buddy`)首页重构为 MainShell 三 Tab,新增知识库/详情/背诵三页,全部走 Riverpod provider 复用现有 `databaseProvider`。agent 写入路径(`save_topic`/`StudyScenario`)零改动。

**Tech Stack:** Flutter + Riverpod + go_router(已有);engine 纯 Dart + sqflite_common。

## Global Constraints

- **引擎零 Flutter 依赖**——`packages/study_engine/` 保持纯 Dart。
- **引擎测试惯例**：`test` 包(非 flutter_test),`sqfliteFfiInit()` + `databaseFactoryFfi` + `inMemoryDatabasePath`,参考现有 `repos_test.dart`。
- **FK 依赖**：`PRAGMA foreign_keys = ON` 已在 `database.dart` onConfigure 启用,`review_schedule` 的 `ON DELETE CASCADE` 依赖它生效——**不得移除该 PRAGMA**。
- **迁移规则**：`kCurrentDbVersion` 2 → 3,迁移函数在 `migrateDatabase` 的 switch 追加 `case 3`。
- **调度算法边界**(spec §3.4,必须逐字遵守)：
  - ease ∈ [1.3, 3.0](`clamp` 后 `.toDouble()`)
  - interval 下限 1 天
  - 首学(`intervalDays == 0`)：remembered → 1, easy → 2, forgot → 1
  - 非首学：forgot → interval=1 + ease-0.2; remembered → `round(interval×ease)` + ease 不变; easy → `round(interval×ease×1.3)` + ease+0.1
- **懒初始化**：`save_topic`/`StudyScenario`/agent 工具 schema **零改动**;背诵时 `getByTopic` 为 null 用 `SpacedRepetitionService.initial` 构造首学记录。
- **消费侧只读**：App 不新增 agent 工具、不新增知识点写入入口;编辑走 AI `update_topic`。
- **导航**：MainShell 底部 `NavigationBar` 三 Tab,顺序固定：知识库 / 背诵 / 悬浮窗。
- **树浏览**：逐级下钻(每层一页)+ 面包屑回退,非展开折叠。
- **搜索**：`onChanged` 防抖 300ms,文本非空才切搜索视图;清空回浏览。
- **provider 类型公开**：聚合类型 `CategoryChild`/`TopicDetail`/`ReviewMode`/`KnowledgeSearchResult` 定义在 `knowledge_providers.dart` 并公开(不加 `_` 前缀,页面跨文件引用)。
- **提交规范**：`feat:`/`docs:`/`fix:` 前缀,信息结尾 `Co-Authored-By: Claude <noreply@anthropic.com>`。
- **测试运行命令**(Windows PowerShell,从仓库根 `D:\my_space\study`):
  - 引擎:`cd packages/study_engine; dart test test/<file>_test.dart`
  - 引擎全量:`cd packages/study_engine; dart analyze; dart test`
  - App:`cd study_buddy; flutter test test/<file>_test.dart`

---

### Task 1: 模型 `ReviewSchedule` + v3 迁移

**Files:**
- Modify: `packages/study_engine/lib/src/models/models.dart`
- Modify: `packages/study_engine/lib/src/db/database_migrations.dart`
- Modify: `packages/study_engine/lib/study_engine.dart`
- Test: `packages/study_engine/test/db_test.dart`

**Interfaces:**
- Produces: `ReviewSchedule` 类 + `ReviewFeedback` 枚举(全字段见下方代码),`kCurrentDbVersion = 3`,迁移函数新增 `_v3`。后续 Task 2/3/4 依赖这些名字。

- [ ] **Step 1: 写失败测试**——改 `db_test.dart`，把建表断言从 8 张改为 9 张(加 `review_schedule`)：

```dart
    for (final t in [
      'category', 'topic', 'topic_edge', 'mastery_log',
      'llm_config', 'agent_memory', 'chat_session', 'chat_message',
      'review_schedule',
    ]) {
      expect(names, contains(t), reason: '缺表: $t');
    }
```

Run: `cd packages/study_engine; dart test test/db_test.dart`
Expected: FAIL(缺 `review_schedule` 表)。

- [ ] **Step 2: 跑测试确认失败**

Run: 同上
Expected: FAIL。

- [ ] **Step 3: 实现模型 + 迁移**

`models.dart` 文件末尾追加(置于 `MasteryLog` 之后、`LlmConfig` 之前的位置均可,保持文件内已有分组风格)：

```dart
/// 背诵反馈三档。
enum ReviewFeedback { forgot, remembered, easy }

/// 间隔重复调度记录。1:1 关联 topic，主键即 topic.id。
/// 懒初始化：首次背诵时才建，save_topic 不写此表。
class ReviewSchedule {
  final int topicId;
  final double easeFactor; // 难度系数，初始 2.5
  final int intervalDays; // 当前间隔天数，首学为 0
  final DateTime nextReviewAt; // 下次到期时间
  final int reviewCount; // 已复习次数
  final DateTime? lastReviewedAt; // 最近一次复习，首次为 null
  const ReviewSchedule({
    required this.topicId,
    required this.easeFactor,
    required this.intervalDays,
    required this.nextReviewAt,
    required this.reviewCount,
    this.lastReviewedAt,
  });

  factory ReviewSchedule.fromMap(Map<String, Object?> m) => ReviewSchedule(
        topicId: m['topic_id'] as int,
        easeFactor: (m['ease_factor'] as num).toDouble(),
        intervalDays: m['interval_days'] as int,
        nextReviewAt: DateTime.fromMillisecondsSinceEpoch(m['next_review_at'] as int),
        reviewCount: m['review_count'] as int,
        lastReviewedAt: m['last_reviewed_at'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(m['last_reviewed_at'] as int),
      );
  Map<String, Object?> toMap() => {
        'topic_id': topicId,
        'ease_factor': easeFactor,
        'interval_days': intervalDays,
        'next_review_at': nextReviewAt.millisecondsSinceEpoch,
        'review_count': reviewCount,
        if (lastReviewedAt != null)
          'last_reviewed_at': lastReviewedAt!.millisecondsSinceEpoch,
      };
}
```

`database_migrations.dart`：`kCurrentDbVersion` 改为 `3`；`migrateDatabase` switch 追加：

```dart
      case 3:
        _v3(batch);
        break;
```

文件末尾追加：

```dart
/// v3：消费侧背诵。新建 review_schedule 表（1:1 topic，懒初始化）。
void _v3(Batch batch) {
  batch.execute('''
    CREATE TABLE review_schedule (
      topic_id         INTEGER PRIMARY KEY,
      ease_factor      REAL    NOT NULL DEFAULT 2.5,
      interval_days    INTEGER NOT NULL DEFAULT 0,
      next_review_at   INTEGER NOT NULL,
      review_count     INTEGER NOT NULL DEFAULT 0,
      last_reviewed_at INTEGER,
      FOREIGN KEY (topic_id) REFERENCES topic(id) ON DELETE CASCADE
    )
  ''');
  batch.execute('CREATE INDEX idx_review_schedule_next ON review_schedule(next_review_at)');
}
```

- [ ] **Step 4: barrel 导出**

`study_engine.dart` 追加一行：

```dart
export 'src/models/models.dart';
```

（已在文件首行——确认 `ReviewSchedule`/`ReviewFeedback` 经 `models.dart` 的现有导出透出即可，无需新增行。）

- [ ] **Step 5: 跑测试确认通过**

Run: `cd packages/study_engine; dart test test/db_test.dart`
Expected: PASS。

- [ ] **Step 6: Commit**

```bash
git add packages/study_engine/lib/src/models/models.dart packages/study_engine/lib/src/db/database_migrations.dart packages/study_engine/lib/study_engine.dart packages/study_engine/test/db_test.dart
git commit -m "feat(engine): ReviewSchedule 模型 + v3 迁移 review_schedule 表"
```

---

### Task 2: `SpacedRepetitionService` 纯函数调度器

**Files:**
- Create: `packages/study_engine/lib/src/review/spaced_repetition_service.dart`
- Modify: `packages/study_engine/lib/study_engine.dart`
- Test: `packages/study_engine/test/spaced_repetition_test.dart`

**Interfaces:**
- Consumes: `ReviewSchedule`/`ReviewFeedback`(Task 1)
- Produces: `SpacedRepetitionService.initial(topicId, now)` 与 `apply(prev, feedback, now)` —— Task 3/4 不用,Task 8(ReviewPage)用。

- [ ] **Step 1: 写失败测试**

`packages/study_engine/test/spaced_repetition_test.dart`(纯函数,无 DB,固定 `now` 测试):

```dart
import 'package:test/test.dart';
import 'package:study_engine/study_engine.dart';

void main() {
  final now = DateTime(2026, 8, 10, 12, 0);

  ReviewSchedule sched({
    double ease = 2.5,
    int interval = 0,
    DateTime? next,
    int count = 0,
  }) =>
      ReviewSchedule(
        topicId: 1,
        easeFactor: ease,
        intervalDays: interval,
        nextReviewAt: next ?? now,
        reviewCount: count,
        lastReviewedAt: null,
      );

  test('首学三档：记得→1天，轻松→2天，忘了→1天', () {
    final remembered = SpacedRepetitionService.apply(sched(), ReviewFeedback.remembered, now);
    expect(remembered.intervalDays, 1);
    expect(remembered.nextReviewAt, now.add(const Duration(days: 1)));
    expect(remembered.easeFactor, 2.5); // 记得不改 ease
    expect(remembered.reviewCount, 1);
    expect(remembered.lastReviewedAt, now);

    final easy = SpacedRepetitionService.apply(sched(), ReviewFeedback.easy, now);
    expect(easy.intervalDays, 2);
    expect(easy.easeFactor, 2.6); // 轻松 +0.1

    final forgot = SpacedRepetitionService.apply(sched(), ReviewFeedback.forgot, now);
    expect(forgot.intervalDays, 1);
    expect(forgot.easeFactor, 2.3); // 忘了 -0.2
  });

  test('非首学乘性增长', () {
    final prev = sched(ease: 2.5, interval: 7, next: now.subtract(const Duration(days: 1)));
    final r = SpacedRepetitionService.apply(prev, ReviewFeedback.remembered, now);
    expect(r.intervalDays, (7 * 2.5).round()); // 18
    expect(r.easeFactor, 2.5);

    final e = SpacedRepetitionService.apply(prev, ReviewFeedback.easy, now);
    expect(e.intervalDays, (7 * 2.5 * 1.3).round()); // 23
    expect(e.easeFactor, 2.6);
  });

  test('忘了重置为 1 天', () {
    final prev = sched(ease: 2.5, interval: 30, next: now.subtract(const Duration(days: 3)));
    final f = SpacedRepetitionService.apply(prev, ReviewFeedback.forgot, now);
    expect(f.intervalDays, 1);
    expect(f.easeFactor, 2.3);
  });

  test('ease 上下限 clamp', () {
    var s = sched(ease: 1.3, interval: 1);
    for (var i = 0; i < 10; i++) {
      s = SpacedRepetitionService.apply(s, ReviewFeedback.forgot, now);
    }
    expect(s.easeFactor, 1.3); // 下限不破

    s = sched(ease: 3.0, interval: 1);
    for (var i = 0; i < 10; i++) {
      s = SpacedRepetitionService.apply(s, ReviewFeedback.easy, now);
    }
    expect(s.easeFactor, 3.0); // 上限不破
  });

  test('interval 下限 1 天（round 得 0 兜底）', () {
    final prev = sched(ease: 1.3, interval: 1);
    final r = SpacedRepetitionService.apply(prev, ReviewFeedback.remembered, now);
    expect(r.intervalDays, 1); // 1*1.3=1.3 → round 1
    final e = SpacedRepetitionService.apply(prev, ReviewFeedback.easy, now);
    expect(e.intervalDays, (1 * 1.3 * 1.3).round()); // 2
  });
}
```

Run: `cd packages/study_engine; dart test test/spaced_repetition_test.dart`
Expected: FAIL(`SpacedRepetitionService` 未定义)。

- [ ] **Step 2: 跑测试确认失败**

Run: 同上
Expected: FAIL。

- [ ] **Step 3: 实现**

`packages/study_engine/lib/src/review/spaced_repetition_service.dart`：

```dart
import '../models/models.dart';

/// 间隔重复调度器（简化 SM-2）。纯函数，无 DB 依赖，可单测。
class SpacedRepetitionService {
  static const double kInitialEase = 2.5;
  static const double kMinEase = 1.3;
  static const double kMaxEase = 3.0;

  /// 首学记录（interval 0 → 首次反馈后落地）。
  static ReviewSchedule initial(int topicId, DateTime now) => ReviewSchedule(
        topicId: topicId,
        easeFactor: kInitialEase,
        intervalDays: 0,
        nextReviewAt: now, // 立即可背
        reviewCount: 0,
        lastReviewedAt: null,
      );

  /// 应用反馈，返回新 schedule。now 由调用方传入（测试可固定时间）。
  static ReviewSchedule apply(
      ReviewSchedule prev, ReviewFeedback feedback, DateTime now) {
    double ease = prev.easeFactor;
    int interval;
    switch (feedback) {
      case ReviewFeedback.forgot:
        ease = (ease - 0.2).clamp(kMinEase, kMaxEase).toDouble();
        interval = 1;
        break;
      case ReviewFeedback.remembered:
        ease = ease.clamp(kMinEase, kMaxEase).toDouble();
        interval = prev.intervalDays == 0
            ? 1
            : (prev.intervalDays * ease).round();
        break;
      case ReviewFeedback.easy:
        ease = (ease + 0.1).clamp(kMinEase, kMaxEase).toDouble();
        interval = prev.intervalDays == 0
            ? 2
            : (prev.intervalDays * ease * 1.3).round();
        break;
    }
    if (interval < 1) interval = 1;
    return ReviewSchedule(
      topicId: prev.topicId,
      easeFactor: ease,
      intervalDays: interval,
      nextReviewAt: now.add(Duration(days: interval)),
      reviewCount: prev.reviewCount + 1,
      lastReviewedAt: now,
    );
  }
}
```

- [ ] **Step 4: barrel 导出**

`study_engine.dart` 追加：

```dart
export 'src/review/spaced_repetition_service.dart';
```

- [ ] **Step 5: 跑测试确认通过**

Run: `cd packages/study_engine; dart test test/spaced_repetition_test.dart`
Expected: PASS。

- [ ] **Step 6: Commit**

```bash
git add packages/study_engine/lib/src/review/spaced_repetition_service.dart packages/study_engine/lib/study_engine.dart packages/study_engine/test/spaced_repetition_test.dart
git commit -m "feat(engine): SpacedRepetitionService 简化 SM-2 调度器"
```

---

### Task 3: `ReviewScheduleRepository`

**Files:**
- Create: `packages/study_engine/lib/src/repos/review_schedule_repository.dart`
- Modify: `packages/study_engine/lib/study_engine.dart`
- Test: `packages/study_engine/test/repos_test.dart`

**Interfaces:**
- Consumes: `ReviewSchedule`(Task 1)、`StudyDatabase`
- Produces: `ReviewScheduleRepository{getByTopic, upsert, findDue}` —— Task 4(`dueQueue` 不再用它,但保留独立用途)、Task 8(ReviewPage 反馈落地)用。
- **`upsert` 必须原子**：用 `conflictAlgorithm: ConflictAlgorithm.replace`(主键冲突即更新),不要「先查后插」。

- [ ] **Step 1: 写失败测试**

`repos_test.dart` 文件末尾(最后一个 `}` 前)追加 3 个测试。复用文件顶部的 `_fresh()`/`sdb`：

```dart
  test('ReviewScheduleRepository getByTopic 无记录返回 null', () async {
    final repo = ReviewScheduleRepository(sdb);
    expect(await repo.getByTopic(999), isNull);
  });

  test('ReviewScheduleRepository upsert 插入与更新（主键原子）', () async {
    final cats = CategoryRepository(sdb);
    final topics = TopicRepository(sdb);
    final catId = await cats.ensurePath(['数学']);
    final now = DateTime.now();
    final tid = await topics.insert(Topic(categoryId: catId, question: 'q', title: 't', summary: 's', createdAt: now, updatedAt: now));
    final repo = ReviewScheduleRepository(sdb);

    final s1 = SpacedRepetitionService.initial(tid, now);
    await repo.upsert(s1);
    expect((await repo.getByTopic(tid))?.intervalDays, 0);

    // 二次 upsert（首次反馈后）不报主键冲突
    final s2 = SpacedRepetitionService.apply(s1, ReviewFeedback.remembered, now);
    await repo.upsert(s2);
    final got = await repo.getByTopic(tid);
    expect(got?.intervalDays, 1);
    expect(got?.reviewCount, 1);
  });

  test('ReviewScheduleRepository findDue 只返回到期且升序', () async {
    final cats = CategoryRepository(sdb);
    final topics = TopicRepository(sdb);
    final catId = await cats.ensurePath(['数学']);
    final now = DateTime(2026, 8, 10, 12, 0);
    final a = await topics.insert(Topic(categoryId: catId, question: 'q1', title: 'A', summary: 's', createdAt: now, updatedAt: now));
    final b = await topics.insert(Topic(categoryId: catId, question: 'q2', title: 'B', summary: 's', createdAt: now, updatedAt: now));
    final c = await topics.insert(Topic(categoryId: catId, question: 'q3', title: 'C', summary: 's', createdAt: now, updatedAt: now));
    final repo = ReviewScheduleRepository(sdb);
    // A 昨天到期，B 今天到期，C 明天到期
    await repo.upsert(SpacedRepetitionService.initial(a, now.subtract(const Duration(days: 1))));
    await repo.upsert(SpacedRepetitionService.initial(b, now));
    await repo.upsert(SpacedRepetitionService.initial(c, now.add(const Duration(days: 1))));

    final due = await repo.findDue(now);
    expect(due.map((s) => s.topicId), [a, b]); // C 未到期排除
    expect(due.first.nextReviewAt.isAfter(due.last.nextReviewAt) == false, isTrue); // 升序
  });

  test('FK 启用：删 topic 连带删 review_schedule（CASCADE 回归）', () async {
    final cats = CategoryRepository(sdb);
    final topics = TopicRepository(sdb);
    final repo = ReviewScheduleRepository(sdb);
    final catId = await cats.ensurePath(['数学']);
    final now = DateTime.now();
    final tid = await topics.insert(Topic(categoryId: catId, question: 'q', title: 't', summary: 's', createdAt: now, updatedAt: now));
    await repo.upsert(SpacedRepetitionService.initial(tid, now));

    await sdb.db.delete('topic', where: 'id = ?', whereArgs: [tid]);
    expect(await repo.getByTopic(tid), isNull, reason: 'FK 未启用，删 topic 后调度残留');
  });
```

Run: `cd packages/study_engine; dart test test/repos_test.dart`
Expected: FAIL(`ReviewScheduleRepository` 未定义)。

- [ ] **Step 2: 跑测试确认失败**

Run: 同上
Expected: FAIL。

- [ ] **Step 3: 实现**

`packages/study_engine/lib/src/repos/review_schedule_repository.dart`：

```dart
import 'package:sqflite_common/sqlite_api.dart';

import '../db/database.dart';
import '../models/models.dart';

class ReviewScheduleRepository {
  final StudyDatabase _db;
  ReviewScheduleRepository(this._db);

  /// 取调度记录，无则返回 null（懒初始化：null 视为首学）。
  Future<ReviewSchedule?> getByTopic(int topicId) async {
    final rows = await _db.db.query('review_schedule',
        where: 'topic_id = ?', whereArgs: [topicId], limit: 1);
    return rows.isEmpty ? null : ReviewSchedule.fromMap(rows.first);
  }

  /// 插入或更新（topic_id 主键冲突用 REPLACE，原子）。
  Future<void> upsert(ReviewSchedule s) async {
    await _db.db.insert('review_schedule', s.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// 到期记录：next_review_at <= now，升序，限量。
  Future<List<ReviewSchedule>> findDue(DateTime now, {int limit = 200}) async {
    final rows = await _db.db.query(
      'review_schedule',
      where: 'next_review_at <= ?',
      whereArgs: [now.millisecondsSinceEpoch],
      orderBy: 'next_review_at ASC',
      limit: limit,
    );
    return rows.map(ReviewSchedule.fromMap).toList();
  }
}
```

- [ ] **Step 4: barrel 导出**

`study_engine.dart` 追加：

```dart
export 'src/repos/review_schedule_repository.dart';
```

- [ ] **Step 5: 跑测试确认通过**

Run: `cd packages/study_engine; dart test test/repos_test.dart`
Expected: PASS(全文件含既有测试)。

- [ ] **Step 6: Commit**

```bash
git add packages/study_engine/lib/src/repos/review_schedule_repository.dart packages/study_engine/lib/study_engine.dart packages/study_engine/test/repos_test.dart
git commit -m "feat(engine): ReviewScheduleRepository 调度记录读写 + findDue"
```

---

### Task 4: `ReviewQueueRepository` 背诵队列

**Files:**
- Create: `packages/study_engine/lib/src/repos/review_queue_repository.dart`
- Modify: `packages/study_engine/lib/study_engine.dart`
- Test: `packages/study_engine/test/repos_test.dart`

**Interfaces:**
- Consumes: `StudyDatabase`
- Produces: `ReviewQueueItem{topicId,title,question}` + `ReviewQueueRepository{dueQueue, todayNewQueue}` —— Task 8(ReviewPage 队列加载)用。
- **`dueQueue` 一次 JOIN 查询,禁止 N+1**(逐 topic 查)。**`todayNewQueue` 直接查 topic 表**(不 join schedule,懒建覆盖)。

- [ ] **Step 1: 写失败测试**

`repos_test.dart` 末尾追加：

```dart
  test('ReviewQueueRepository dueQueue JOIN 一次查 + 限量', () async {
    final cats = CategoryRepository(sdb);
    final topics = TopicRepository(sdb);
    final repo = ReviewQueueRepository(sdb);
    final catId = await cats.ensurePath(['数学']);
    final now = DateTime(2026, 8, 10, 12, 0);
    final a = await topics.insert(Topic(categoryId: catId, question: 'q1', title: '洛必达', summary: 's', createdAt: now, updatedAt: now));
    await topics.insert(Topic(categoryId: catId, question: 'q2', title: '夹逼', summary: 's', createdAt: now, updatedAt: now));
    final sched = ReviewScheduleRepository(sdb);
    await sched.upsert(SpacedRepetitionService.initial(a, now.subtract(const Duration(days: 1))));

    final q = await repo.dueQueue(now);
    expect(q, hasLength(1));
    expect(q.first.topicId, a);
    expect(q.first.title, '洛必达');
    expect(q.first.question, 'q1');

    final capped = await repo.dueQueue(now, limit: 0);
    expect(capped, isEmpty);
  });

  test('ReviewQueueRepository todayNewQueue 含无 schedule 的今日新增 + 跨天边界', () async {
    final cats = CategoryRepository(sdb);
    final topics = TopicRepository(sdb);
    final repo = ReviewQueueRepository(sdb);
    final catId = await cats.ensurePath(['数学']);
    final dayStart = DateTime(2026, 8, 10, 0, 0);
    final today = dayStart.add(const Duration(hours: 10));
    final yesterday = dayStart.subtract(const Duration(minutes: 1));
    // 今天新存（无 schedule）
    final a = await topics.insert(Topic(categoryId: catId, question: 'q1', title: '今天新增', summary: 's', createdAt: today, updatedAt: today));
    // 昨天存（有 schedule，不算今日新增）
    final b = await topics.insert(Topic(categoryId: catId, question: 'q2', title: '昨天', summary: 's', createdAt: yesterday, updatedAt: yesterday));
    await ReviewScheduleRepository(sdb).upsert(SpacedRepetitionService.initial(b, yesterday));

    final q = await repo.todayNewQueue(dayStart);
    expect(q.map((i) => i.topicId), [a]); // b 排除
    expect(q.first.title, '今天新增');
  });
```

Run: `cd packages/study_engine; dart test test/repos_test.dart`
Expected: FAIL(`ReviewQueueRepository` 未定义)。

- [ ] **Step 2: 跑测试确认失败**

Run: 同上
Expected: FAIL。

- [ ] **Step 3: 实现**

`packages/study_engine/lib/src/repos/review_queue_repository.dart`：

```dart
import '../db/database.dart';

/// 可背诵的知识点轻量项。
class ReviewQueueItem {
  final int topicId;
  final String title;
  final String question;
  ReviewQueueItem(this.topicId, this.title, this.question);
}

class ReviewQueueRepository {
  final StudyDatabase _db;
  ReviewQueueRepository(this._db);

  /// 到期复习队列：有 schedule 且 next_review_at <= now，按到期升序。
  /// 一次 JOIN 查询（无 N+1）。
  Future<List<ReviewQueueItem>> dueQueue(DateTime now, {int limit = 200}) async {
    final rows = await _db.db.rawQuery(
      '''
      SELECT t.id, t.title, t.question
      FROM review_schedule s
      JOIN topic t ON t.id = s.topic_id
      WHERE s.next_review_at <= ?
      ORDER BY s.next_review_at ASC
      LIMIT ?
      ''',
      [now.millisecondsSinceEpoch, limit],
    );
    return rows
        .map((r) =>
            ReviewQueueItem(r['id'] as int, r['title'] as String, r['question'] as String))
        .toList();
  }

  /// 今日新增队列：topic.created_at >= startOfDay，按创建升序。
  /// 直接查 topic 表——不依赖 schedule（懒建，今日新增可能尚无调度）。
  Future<List<ReviewQueueItem>> todayNewQueue(DateTime startOfDay) async {
    final rows = await _db.db.rawQuery(
      '''
      SELECT id, title, question
      FROM topic
      WHERE created_at >= ?
      ORDER BY created_at ASC
      ''',
      [startOfDay.millisecondsSinceEpoch],
    );
    return rows
        .map((r) =>
            ReviewQueueItem(r['id'] as int, r['title'] as String, r['question'] as String))
        .toList();
  }
}
```

- [ ] **Step 4: barrel 导出**

`study_engine.dart` 追加：

```dart
export 'src/repos/review_queue_repository.dart';
```

- [ ] **Step 5: 跑测试确认通过 + 引擎全量回归**

Run: `cd packages/study_engine; dart analyze; dart test`
Expected: analyze 0 issues;全部 PASS(含既有 31 + 新增)。

- [ ] **Step 6: Commit**

```bash
git add packages/study_engine/lib/src/repos/review_queue_repository.dart packages/study_engine/lib/study_engine.dart packages/study_engine/test/repos_test.dart
git commit -m "feat(engine): ReviewQueueRepository 两背诵队列（due/todayNew）"
```

---

### Task 5: 导航壳 MainShell + providers + 悬浮窗平移

**Files:**
- Create: `study_buddy/lib/core/providers/knowledge_providers.dart`
- Create: `study_buddy/lib/features/home/main_shell.dart`
- Create: `study_buddy/lib/features/home/overlay_settings_page.dart`
- Create: `study_buddy/lib/features/knowledge/knowledge_base_page.dart`（占位，Task 6 替换）
- Create: `study_buddy/lib/features/review/review_page.dart`（占位，Task 8 替换）
- Modify: `study_buddy/lib/features/home/home_page.dart`（删除）
- Modify: `study_buddy/lib/router.dart`
- Modify: `study_buddy/lib/app.dart`
- Test: `study_buddy/test/widget_test.dart`

**Interfaces:**
- Consumes: 引擎 barrel(Task 1-4)、现有 `databaseProvider`/`screenshotProvider`/`agentSessionProvider`。
- Produces: `MainShell`(三 Tab)、`KnowledgeBasePage`/`ReviewPage`/`OverlaySettingsPage` 类名、`knowledge_providers.dart` 全部类型与 provider —— Task 6/7/8 引用。
- **provider 全部 `FutureProvider`**(内部 `await databaseProvider.future` 构造 repo),与 `agentSessionProvider` 风格一致;聚合类型公开。

- [ ] **Step 1: 写失败测试**

`study_buddy/test/widget_test.dart` 整体替换：

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:study_buddy/app.dart';

void main() {
  testWidgets('app 启动并渲染三 Tab 导航', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: StudyBuddyApp()));
    await tester.pump();
    // MainShell 同步渲染 NavigationBar（不依赖 DB 就绪）。
    // 注意：占位页 body 与 Tab label 同名的文本会有多个，只断言 NavigationBar。
    expect(find.byType(NavigationBar), findsOneWidget);
  });
}
```

Run: `cd study_buddy; flutter test test/widget_test.dart`
Expected: FAIL(`MainShell` 尚未接入,找不到 NavigationBar)。

- [ ] **Step 2: 跑测试确认失败**

Run: 同上
Expected: FAIL。

- [ ] **Step 3: 实现 providers**

`study_buddy/lib/core/providers/knowledge_providers.dart`：

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:study_engine/study_engine.dart';

import 'database_provider.dart';

/// 知识库某层列表项：分类或知识点。
class CategoryChild {
  final bool isCategory;
  final int id; // category.id 或 topic.id
  final String name; // category.name 或 topic.title
  final bool hasChildren; // 仅分类有意义：是否有子分类
  const CategoryChild({
    required this.isCategory,
    required this.id,
    required this.name,
    this.hasChildren = false,
  });
}

/// 详情页聚合数据。
class TopicDetail {
  final Topic topic;
  final List<String> path; // 分类路径段
  final List<TopicEdgeView> edges; // 关联边（prerequisite 在前）
  const TopicDetail({required this.topic, required this.path, required this.edges});
}

/// 搜索结果项：id + 标题 + 路径。
class KnowledgeSearchResult {
  final int id;
  final String title;
  final List<String> path;
  const KnowledgeSearchResult({required this.id, required this.title, required this.path});
}

/// 背诵模式。
enum ReviewMode { todayNew, due }

// ---- repository providers（FutureProvider：DB 就绪后构造）----

final categoryRepositoryProvider =
    FutureProvider<CategoryRepository>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  return CategoryRepository(db);
});

final topicRepositoryProvider = FutureProvider<TopicRepository>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  return TopicRepository(db);
});

final topicEdgeRepositoryProvider =
    FutureProvider<TopicEdgeRepository>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  return TopicEdgeRepository(db);
});

final reviewScheduleRepositoryProvider =
    FutureProvider<ReviewScheduleRepository>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  return ReviewScheduleRepository(db);
});

final reviewQueueRepositoryProvider =
    FutureProvider<ReviewQueueRepository>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  return ReviewQueueRepository(db);
});

// ---- 聚合 providers ----

/// 某层列表：子分类（前置）+ 直挂知识点。parentId 为 null 表根级。
final categoryChildrenProvider =
    FutureProvider.family<List<CategoryChild>, int?>((ref, parentId) async {
  final cats = await ref.watch(categoryRepositoryProvider.future);
  final topics = await ref.watch(topicRepositoryProvider.future);

  final children = await cats.findChildren(parentId);
  final list = <CategoryChild>[];
  for (final c in children) {
    final sub = await cats.findChildren(c.id);
    list.add(CategoryChild(
      isCategory: true,
      id: c.id!,
      name: c.name,
      hasChildren: sub.isNotEmpty,
    ));
  }
  if (parentId != null) {
    final direct = await topics.findByCategory(parentId);
    list.addAll(direct.map(
        (t) => CategoryChild(isCategory: false, id: t.id!, name: t.title)));
  }
  return list;
});

/// 详情聚合：topic + 路径 + 边（prerequisite 在前）。
final topicDetailProvider =
    FutureProvider.family<TopicDetail, int>((ref, topicId) async {
  final topics = await ref.watch(topicRepositoryProvider.future);
  final cats = await ref.watch(categoryRepositoryProvider.future);
  final edges = await ref.watch(topicEdgeRepositoryProvider.future);

  final topic = await topics.findById(topicId);
  if (topic == null) throw StateError('知识点不存在: $topicId');
  final path = await cats.pathOf(topic.categoryId);
  final edgeList = await edges.findByTopic(topicId);
  edgeList.sort((a, b) {
    if (a.type == 'prerequisite' && b.type != 'prerequisite') return -1;
    if (b.type == 'prerequisite' && a.type != 'prerequisite') return 1;
    return 0;
  });
  return TopicDetail(topic: topic, path: path, edges: edgeList);
});

/// 关键词搜索：title + 路径。
final knowledgeSearchProvider =
    FutureProvider.family<List<KnowledgeSearchResult>, String>(
        (ref, keyword) async {
  final topics = await ref.watch(topicRepositoryProvider.future);
  final cats = await ref.watch(categoryRepositoryProvider.future);
  final r = await topics.search(keyword, limit: 30);
  final results = <KnowledgeSearchResult>[];
  for (final item in r.items) {
    final path = await cats.pathOf(item.categoryId);
    results.add(KnowledgeSearchResult(id: item.id, title: item.title, path: path));
  }
  return results;
});
```

- [ ] **Step 4: 实现 MainShell + 占位页 + 悬浮窗平移**

`study_buddy/lib/features/home/main_shell.dart`（完整版,含冷启动截图消费）:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../main.dart' show PendingScreenshotStore;
import '../../features/external_qbank/ai_panel_sheet.dart';
import '../knowledge/knowledge_base_page.dart';
import '../review/review_page.dart';
import 'overlay_settings_page.dart';

/// 应用主壳：底部三 Tab（知识库 / 背诵 / 悬浮窗）。
class MainShell extends StatefulWidget {
  const MainShell({super.key});
  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    // 冷启动降级：弹出待处理截图的 AI 面板（原 HomePage 的 _consumePendingScreenshot 移此）
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final pending = PendingScreenshotStore.pending;
      if (pending != null && mounted) {
        PendingScreenshotStore.pending = null;
        await showAiPanel(context, screenshot: pending);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: const [
          KnowledgeBasePage(),
          ReviewPage(),
          OverlaySettingsPage(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.menu_book_outlined),
            selectedIcon: Icon(Icons.menu_book),
            label: '知识库',
          ),
          NavigationDestination(
            icon: Icon(Icons.style_outlined),
            selectedIcon: Icon(Icons.style),
            label: '背诵',
          ),
          NavigationDestination(
            icon: Icon(Icons.screenshot_monitor_outlined),
            selectedIcon: Icon(Icons.screenshot_monitor),
            label: '悬浮窗',
          ),
        ],
      ),
    );
  }
}
```

占位 `knowledge_base_page.dart`(Task 6 整体替换)：

```dart
import 'package:flutter/material.dart';

class KnowledgeBasePage extends StatelessWidget {
  const KnowledgeBasePage({super.key});
  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: Text('知识库')));
  }
}
```

占位 `review_page.dart`(Task 8 整体替换)：

```dart
import 'package:flutter/material.dart';

class ReviewPage extends StatelessWidget {
  const ReviewPage({super.key});
  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: Text('背诵')));
  }
}
```

`overlay_settings_page.dart`——**平移原 `home_page.dart` 全部内容**(悬浮窗状态检查、权限引导、检查更新、`_checkForUpdate` 方法),仅做四处调整:
1. 类名 `HomePage` → `OverlaySettingsPage`,文件名随之。
2. AppBar 标题 `'Study Buddy'` → `'悬浮窗'`。
3. **删除** `_consumePendingScreenshot`(冷启动待处理截图消费)——已并入 `MainShell.initState`(见上)。
4. **删除** `import '../../main.dart' show PendingScreenshotStore`(不再需要);`home_page` 中被平移内容实际用到的其余 import 全部保留。

`home_page.dart` 删除。

- [ ] **Step 5: 路由**

`router.dart` 替换（本任务只接 `/` 与 `/permission-guide`;`/topic/:id` 留到 Task 7 接入,避免 import 尚不存在的 `topic_detail_page.dart` 导致编译失败）:

```dart
import 'package:go_router/go_router.dart';
import 'features/home/main_shell.dart';
import 'features/overlay/permission_guide_page.dart';

GoRouter buildRouter() {
  return GoRouter(
    routes: [
      GoRoute(path: '/', builder: (context, state) => const MainShell()),
      GoRoute(
        path: '/permission-guide',
        builder: (context, state) => const PermissionGuidePage(),
      ),
    ],
  );
}
```

- [ ] **Step 6: 跑测试确认通过**

Run: `cd study_buddy; flutter analyze; flutter test`
Expected: analyze 0 issues;widget_test PASS;其余既有 App 测试 PASS。

- [ ] **Step 7: Commit**

```bash
git add study_buddy/lib/core/providers/knowledge_providers.dart study_buddy/lib/features/home/main_shell.dart study_buddy/lib/features/home/overlay_settings_page.dart study_buddy/lib/features/knowledge/knowledge_base_page.dart study_buddy/lib/features/review/review_page.dart study_buddy/lib/features/home/home_page.dart study_buddy/lib/router.dart study_buddy/test/widget_test.dart
git commit -m "feat(app): MainShell 三 Tab 导航 + knowledge providers + 悬浮窗平移"
```

---

### Task 6: KnowledgeBasePage 知识树浏览 + 搜索

**Files:**
- Modify: `study_buddy/lib/features/knowledge/knowledge_base_page.dart`（占位 → 完整实现）
- Test: `study_buddy/test/knowledge_base_page_test.dart`

**Interfaces:**
- Consumes: `categoryChildrenProvider`/`knowledgeSearchProvider`/`categoryRepositoryProvider`(Task 5)、go_router。
- Produces: 完整 `KnowledgeBasePage`(浏览 + 搜索双视图)。

- [ ] **Step 1: 写失败测试**

`study_buddy/test/knowledge_base_page_test.dart`：

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:study_buddy/core/providers/knowledge_providers.dart';
import 'package:study_buddy/features/knowledge/knowledge_base_page.dart';
import 'package:study_engine/study_engine.dart';

void main() {
  testWidgets('浏览视图渲染分类与知识点混排', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          categoryChildrenProvider.overrideWith(
            (ref, arg) async => const [
              CategoryChild(isCategory: true, id: 1, name: '数学', hasChildren: true),
              CategoryChild(isCategory: false, id: 11, name: '韦达定理'),
            ],
          ),
        ],
        child: const MaterialApp(home: KnowledgeBasePage()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('数学'), findsOneWidget);
    expect(find.text('韦达定理'), findsOneWidget);
  });
}
```

Run: `cd study_buddy; flutter test test/knowledge_base_page_test.dart`
Expected: FAIL(占位页只显示「知识库」文本)。

- [ ] **Step 2: 跑测试确认失败**

Run: 同上
Expected: FAIL。

- [ ] **Step 3: 实现 KnowledgeBasePage**

整体替换 `knowledge_base_page.dart`：

```dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers/knowledge_providers.dart';

class KnowledgeBasePage extends ConsumerStatefulWidget {
  const KnowledgeBasePage({super.key});
  @override
  ConsumerState<KnowledgeBasePage> createState() => _KnowledgeBasePageState();
}

class _KnowledgeBasePageState extends ConsumerState<KnowledgeBasePage> {
  final TextEditingController _searchCtrl = TextEditingController();
  Timer? _debounce;
  List<String> _path = []; // 当前分类路径，空表根级
  int? _currentCategoryId; // 当前层 parentId
  final List<int> _depthIds = []; // 逐级下钻保存的层级 id 链，面包屑回退用

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  String get _keyword => _searchCtrl.text.trim();

  void _onSearchChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted) setState(() {});
    });
  }

  void _drillDown(CategoryChild child) {
    setState(() {
      _path = [..._path, child.name];
      _depthIds.add(child.id);
      _currentCategoryId = child.id;
    });
  }

  /// 面包屑回退到指定深度。depth=0 回根级。
  void _goToDepth(int depth) {
    setState(() {
      _path = _path.sublist(0, depth);
      _depthIds.removeRange(depth, _depthIds.length);
      _currentCategoryId = depth == 0 ? null : _depthIds[depth - 1];
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('知识库')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: TextField(
              controller: _searchCtrl,
              onChanged: _onSearchChanged,
              decoration: const InputDecoration(
                hintText: '搜索知识点',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
          Expanded(child: _keyword.isEmpty ? _buildBrowse() : _buildSearch()),
        ],
      ),
    );
  }

  Widget _buildBrowse() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildBreadcrumb(),
        Expanded(
          child: categoryChildrenProvider(_currentCategoryId).when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => _ErrorRetry(
              message: '加载失败: $e',
              onRetry: () => setState(() {}),
            ),
            data: (list) {
              if (list.isEmpty) {
                return Center(
                  child: Text(
                    _currentCategoryId == null
                        ? '知识库还是空的，用悬浮窗截图让 AI 帮你存知识点'
                        : '这个分类下还没有知识点',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.grey),
                  ),
                );
              }
              return ListView.builder(
                itemCount: list.length,
                itemBuilder: (context, i) {
                  final child = list[i];
                  if (child.isCategory) {
                    return ListTile(
                      leading: const Icon(Icons.folder_outlined),
                      title: Text(child.name),
                      trailing: child.hasChildren
                          ? const Icon(Icons.chevron_right)
                          : null,
                      onTap: () => _drillDown(child),
                    );
                  }
                  return ListTile(
                    leading: const Icon(Icons.description_outlined),
                    title: Text(child.name),
                    onTap: () => context.push('/topic/${child.id}'),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildBreadcrumb() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          TextButton(
            onPressed: _path.isEmpty
                ? null
                : () {
                    setState(() {
                      _path = [];
                      _currentCategoryId = null;
                    });
                  },
            child: const Text('全部'),
          ),
          for (var i = 0; i < _path.length; i++)
            TextButton(
              onPressed: () => _goToDepth(i),
              child: Text(_path[i]),
            ),
        ],
      ),
    );
  }

  Widget _buildSearch() {
    return knowledgeSearchProvider(_keyword).when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => _ErrorRetry(
        message: '搜索失败: $e',
        onRetry: () => setState(() {}),
      ),
      data: (results) {
        if (results.isEmpty) {
          return const Center(
            child: Text('未找到相关知识点', style: TextStyle(color: Colors.grey)),
          );
        }
        return ListView.builder(
          itemCount: results.length,
          itemBuilder: (context, i) {
            final r = results[i];
            return ListTile(
              leading: const Icon(Icons.description_outlined),
              title: Text(r.title),
              subtitle: Text(r.path.join(' / ')),
              onTap: () => context.push('/topic/${r.id}'),
            );
          },
        );
      },
    );
  }
}

class _ErrorRetry extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorRetry({required this.message, required this.onRetry});
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 8),
          FilledButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd study_buddy; flutter analyze; flutter test test/knowledge_base_page_test.dart`
Expected: analyze 0 issues;测试 PASS。

- [ ] **Step 5: Commit**

```bash
git add study_buddy/lib/features/knowledge/knowledge_base_page.dart study_buddy/test/knowledge_base_page_test.dart
git commit -m "feat(app): KnowledgeBasePage 知识树下钻 + 搜索"
```

---

### Task 7: TopicDetailPage 知识点详情

**Files:**
- Create: `study_buddy/lib/features/knowledge/topic_detail_page.dart`
- Modify: `study_buddy/lib/router.dart`（接入 `/topic/:id`）
- Test: `study_buddy/test/topic_detail_page_test.dart`

**Interfaces:**
- Consumes: `topicDetailProvider`(Task 5)、go_router。
- Produces: `TopicDetailPage(topicId: int)`。

- [ ] **Step 1: 写失败测试**

`study_buddy/test/topic_detail_page_test.dart`：

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:study_buddy/core/providers/knowledge_providers.dart';
import 'package:study_buddy/features/knowledge/topic_detail_page.dart';
import 'package:study_engine/study_engine.dart';

void main() {
  final topic = Topic(
    id: 1,
    categoryId: 10,
    question: '什么是韦达定理？',
    title: '韦达定理',
    summary: '一元二次方程根与系数的关系',
    createdAt: DateTime(2026, 8, 10),
    updatedAt: DateTime(2026, 8, 10),
  );

  testWidgets('详情渲染引子/答案/路径/关联边', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          topicDetailProvider.overrideWith(
            (ref, arg) async => TopicDetail(
              topic: topic,
              path: const ['数学', '代数'],
              edges: const [
                TopicEdgeView('prerequisite', 2, '一元二次方程'),
                TopicEdgeView('related', 3, '根与系数'),
              ],
            ),
          ),
        ],
        child: const MaterialApp(home: TopicDetailPage(topicId: 1)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('韦达定理'), findsWidgets);
    expect(find.text('什么是韦达定理？'), findsOneWidget);
    expect(find.text('一元二次方程根与系数的关系'), findsOneWidget);
    expect(find.text('数学 / 代数'), findsOneWidget);
    expect(find.text('一元二次方程'), findsOneWidget); // 关联边对端
  });

  testWidgets('无关联边时隐藏关联区块', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          topicDetailProvider.overrideWith(
            (ref, arg) async => TopicDetail(topic: topic, path: const ['数学'], edges: const []),
          ),
        ],
        child: const MaterialApp(home: TopicDetailPage(topicId: 1)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('🔗 关联'), findsNothing);
  });
}
```

Run: `cd study_buddy; flutter test test/topic_detail_page_test.dart`
Expected: FAIL(文件/类不存在)。

- [ ] **Step 2: 跑测试确认失败**

Run: 同上
Expected: FAIL。

- [ ] **Step 3: 实现 TopicDetailPage + 路由接入**

`study_buddy/lib/features/knowledge/topic_detail_page.dart`：

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers/knowledge_providers.dart';

class TopicDetailPage extends ConsumerWidget {
  const TopicDetailPage({super.key, required this.topicId});
  final int topicId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detailAsync = ref.watch(topicDetailProvider(topicId));
    return Scaffold(
      appBar: AppBar(title: const Text('知识点')),
      body: detailAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('加载失败: $e'),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: () => ref.invalidate(topicDetailProvider(topicId)),
                child: const Text('重试'),
              ),
            ],
          ),
        ),
        data: (detail) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(detail.topic.title,
                style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 4),
            Text(detail.path.join(' / '),
                style: TextStyle(color: Colors.grey.shade600, fontSize: 13)),
            const Divider(height: 24),
            const Text('📖 引子', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(detail.topic.question,
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 16),
            const Text('💡 答案', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            SelectableText(detail.topic.summary,
                style: Theme.of(context).textTheme.bodyLarge),
            if (detail.edges.isNotEmpty) ...[
              const Divider(height: 32),
              const Text('🔗 关联', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              ...detail.edges.map((e) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      e.type == 'prerequisite'
                          ? Icons.subdirectory_arrow_right
                          : Icons.link,
                      size: 20,
                    ),
                    title: Text(e.otherTitle),
                    subtitle: Text(
                      e.type == 'prerequisite' ? '前置依赖' : '相关',
                      style: const TextStyle(fontSize: 12),
                    ),
                    onTap: () => context.push('/topic/${e.otherId}'),
                  )),
            ],
          ],
        ),
      ),
    );
  }
}
```

`router.dart` 在 Task 5 版本基础上追加 `/topic/:id`(恢复 Task 5 Step 5 中暂缓的 import 与路由)：

```dart
import 'package:go_router/go_router.dart';
import 'features/home/main_shell.dart';
import 'features/knowledge/topic_detail_page.dart';
import 'features/overlay/permission_guide_page.dart';

GoRouter buildRouter() {
  return GoRouter(
    routes: [
      GoRoute(path: '/', builder: (context, state) => const MainShell()),
      GoRoute(
        path: '/permission-guide',
        builder: (context, state) => const PermissionGuidePage(),
      ),
      GoRoute(
        path: '/topic/:id',
        builder: (context, state) =>
            TopicDetailPage(topicId: int.parse(state.pathParameters['id']!)),
      ),
    ],
  );
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd study_buddy; flutter analyze; flutter test test/topic_detail_page_test.dart`
Expected: analyze 0 issues;测试 PASS。

- [ ] **Step 5: Commit**

```bash
git add study_buddy/lib/features/knowledge/topic_detail_page.dart study_buddy/lib/router.dart study_buddy/test/topic_detail_page_test.dart
git commit -m "feat(app): TopicDetailPage 知识点详情 + /topic/:id 路由"
```

---

### Task 8: ReviewPage 背诵卡片(间隔重复)

**Files:**
- Modify: `study_buddy/lib/features/review/review_page.dart`（占位 → 完整实现）
- Test: `study_buddy/test/review_page_test.dart`

**Interfaces:**
- Consumes: `reviewQueueRepositoryProvider`/`reviewScheduleRepositoryProvider`/`topicRepositoryProvider`(Task 5)、`SpacedRepetitionService`(Task 2)。
- Produces: 完整 `ReviewPage`(两模式 + 卡片状态机 + 三档反馈 + 统计)。
- **对 spec §4.6 的说明**：spec 列了 `reviewQueueProvider`(family<ReviewMode,…>),本计划**不建它**——ReviewPage 直接 `ref.read(reviewQueueRepositoryProvider.future)` 加载队列并自管列表状态,好处是测试能粒度 override repo(见 Step 1 的 Fake 类)。功能等价,属实现简化,不违反 spec。

- [ ] **Step 1: 写失败测试**

`study_buddy/test/review_page_test.dart`：

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:study_buddy/core/providers/knowledge_providers.dart';
import 'package:study_buddy/features/review/review_page.dart';
import 'package:study_engine/study_engine.dart';

/// 假队列仓库：todayNew 返回两张卡，due 为空。
class FakeQueueRepository implements ReviewQueueRepository {
  @override
  Future<List<ReviewQueueItem>> dueQueue(DateTime now, {int limit = 200}) async => [];
  @override
  Future<List<ReviewQueueItem>> todayNewQueue(DateTime startOfDay) async => const [
        ReviewQueueItem(1, '洛必达法则', '如何求0/0型极限？'),
        ReviewQueueItem(2, '夹逼定理', '如何证明极限存在？'),
      ];
}

/// 假调度仓库：记录 upsert 调用。
class FakeScheduleRepository implements ReviewScheduleRepository {
  final List<ReviewSchedule> saved = [];
  @override
  Future<ReviewSchedule?> getByTopic(int topicId) async => null; // 全部视为首学
  @override
  Future<void> upsert(ReviewSchedule s) async => saved.add(s);
  @override
  Future<List<ReviewSchedule>> findDue(DateTime now, {int limit = 200}) async => [];
}

void main() {
  late FakeScheduleRepository fakeSched;

  Widget build() => ProviderScope(
        overrides: [
          reviewQueueRepositoryProvider.overrideWith((ref) async => FakeQueueRepository()),
          reviewScheduleRepositoryProvider.overrideWith((ref) async => fakeSched),
        ],
        child: const MaterialApp(home: ReviewPage()),
      );

  setUp(() => fakeSched = FakeScheduleRepository());

  testWidgets('卡片流程：引子→揭晓→三档→下一张→统计', (tester) async {
    await tester.pumpWidget(build());
    await tester.pumpAndSettle();

    // 第一张引子
    expect(find.text('如何求0/0型极限？'), findsOneWidget);
    expect(find.text('揭晓答案'), findsOneWidget);

    await tester.tap(find.text('揭晓答案'));
    await tester.pumpAndSettle();

    // 揭晓后显示答案 + 三档
    expect(find.text('记得'), findsOneWidget);
    expect(find.text('忘了'), findsOneWidget);
    expect(find.text('轻松'), findsOneWidget);

    await tester.tap(find.text('记得'));
    await tester.pumpAndSettle();

    // 第二张引子
    expect(find.text('如何证明极限存在？'), findsOneWidget);
    expect(fakeSched.saved, hasLength(1)); // 首学记得 → interval 1
    expect(fakeSched.saved.first.intervalDays, 1);

    // 跳过第二张的反馈：直接验证状态可前进——再揭晓 + 轻松
    await tester.tap(find.text('揭晓答案'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('轻松'));
    await tester.pumpAndSettle();

    // 队列耗尽 → 统计
    expect(fakeSched.saved, hasLength(2));
    expect(fakeSched.saved.last.intervalDays, 2); // 首学轻松
    expect(find.textContaining('记得 1'), findsOneWidget);
    expect(find.textContaining('轻松 1'), findsOneWidget);
  });
}
```

Run: `cd study_buddy; flutter test test/review_page_test.dart`
Expected: FAIL(占位页只显示「背诵」文本)。

- [ ] **Step 2: 跑测试确认失败**

Run: 同上
Expected: FAIL。

- [ ] **Step 3: 实现 ReviewPage**

整体替换 `review_page.dart`：

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:study_engine/study_engine.dart';

import '../../core/providers/knowledge_providers.dart';

class ReviewPage extends ConsumerStatefulWidget {
  const ReviewPage({super.key});
  @override
  ConsumerState<ReviewPage> createState() => _ReviewPageState();
}

class _ReviewPageState extends ConsumerState<ReviewPage> {
  ReviewMode _mode = ReviewMode.todayNew;
  List<ReviewQueueItem> _queue = [];
  ReviewQueueItem? _current;
  bool _revealed = false;
  String _answerText = ''; // 揭晓时从 topic 拉取的答案正文
  bool _loading = true;
  String? _error;
  int _remembered = 0, _forgot = 0, _easy = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final repo = await ref.read(reviewQueueRepositoryProvider.future);
      final now = DateTime.now();
      final day = DateTime(now.year, now.month, now.day);
      final q = _mode == ReviewMode.todayNew
          ? await repo.todayNewQueue(day)
          : await repo.dueQueue(now);
      if (!mounted) return;
      setState(() {
        _queue = q;
        _current = q.isEmpty ? null : q.first;
        _revealed = false;
        _answerText = '';
        _remembered = 0;
        _forgot = 0;
        _easy = 0;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  /// 揭晓答案：从 topic 表拉取答案正文。拉取失败回退标题并提示。
  Future<void> _reveal() async {
    final item = _current;
    if (item == null) return;
    try {
      final topics = await ref.read(topicRepositoryProvider.future);
      final topic = await topics.findById(item.topicId);
      if (!mounted) return;
      setState(() {
        _answerText = topic?.summary ?? item.title;
        _revealed = true;
      });
      if (topic == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('知识点不存在，已回退显示标题')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _answerText = item.title; // 拉取失败回退标题，卡仍可推进
        _revealed = true;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('加载答案失败: $e')),
      );
    }
  }

  Future<void> _submit(ReviewFeedback feedback) async {
    final item = _current;
    if (item == null) return;
    try {
      final schedRepo = await ref.read(reviewScheduleRepositoryProvider.future);
      final now = DateTime.now();
      final prev = await schedRepo.getByTopic(item.topicId);
      final base = prev ?? SpacedRepetitionService.initial(item.topicId, now);
      final next = SpacedRepetitionService.apply(base, feedback, now);
      await schedRepo.upsert(next);
      if (!mounted) return;
      setState(() {
        switch (feedback) {
          case ReviewFeedback.remembered:
            _remembered++;
            break;
          case ReviewFeedback.forgot:
            _forgot++;
            break;
          case ReviewFeedback.easy:
            _easy++;
            break;
        }
        _queue = _queue.sublist(1);
        _current = _queue.isEmpty ? null : _queue.first;
        _revealed = false;
        _answerText = '';
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存复习记录失败: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('背诵')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: SegmentedButton<ReviewMode>(
              segments: const [
                ButtonSegment(
                  value: ReviewMode.todayNew,
                  label: Text('今日新增'),
                  icon: Icon(Icons.fiber_new),
                ),
                ButtonSegment(
                  value: ReviewMode.due,
                  label: Text('到期复习'),
                  icon: Icon(Icons.schedule),
                ),
              ],
              selected: {_mode},
              onSelectionChanged: (s) {
                if (s.first == _mode) return;
                setState(() => _mode = s.first);
                _load();
              },
            ),
          ),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('加载失败: $_error'),
            const SizedBox(height: 8),
            FilledButton(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }
    if (_current == null) {
      if (_remembered + _forgot + _easy == 0) {
        // 空状态：还没开始背
        return Center(
          child: Text(
            _mode == ReviewMode.todayNew ? '今天还没有新增知识点' : '今日已背完 🎉',
            style: const TextStyle(color: Colors.grey),
          ),
        );
      }
      // 本轮统计
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('本轮背诵完成', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            Text('共 ${_remembered + _forgot + _easy} 张'),
            Text('记得 $_remembered · 忘了 $_forgot · 轻松 $_easy'),
            const SizedBox(height: 16),
            FilledButton(onPressed: _load, child: const Text('再来一轮')),
          ],
        ),
      );
    }
    // 卡片
    final item = _current!;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('第 ${_queue.length} 张剩余',
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 16),
              Text(item.question,
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 24),
              if (_revealed) ...[
                const Divider(),
                const SizedBox(height: 8),
                Text('答案', style: const TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                SelectableText(_answerText),
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.tonal(
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.red.shade100,
                        ),
                        onPressed: () => _submit(ReviewFeedback.forgot),
                        child: const Text('忘了'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton(
                        onPressed: () => _submit(ReviewFeedback.remembered),
                        child: const Text('记得'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton.tonal(
                        onPressed: () => _submit(ReviewFeedback.easy),
                        child: const Text('轻松'),
                      ),
                    ),
                  ],
                ),
              ] else
                FilledButton(
                  onPressed: _reveal,
                  child: const Text('揭晓答案'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: 跑测试确认通过 + 全量回归**

Run: `cd study_buddy; flutter analyze; flutter test`
Expected: analyze 0 issues;全部 PASS(含既有 App 测试)。

- [ ] **Step 5: Commit**

```bash
git add study_buddy/lib/features/review/review_page.dart study_buddy/test/review_page_test.dart
git commit -m "feat(app): ReviewPage 背诵卡片 + 间隔重复反馈"
```

---

## 计划自审记录

- **Spec 覆盖**：§3.1 迁移(→T1)、§3.2 模型(→T1)、§3.3 调度仓库(→T3)、§3.4 算法(→T2)、§3.5 队列(→T4)、§3.6 barrel(→T1-4 分散)、§4.1 路由/壳(→T5)、§4.2 悬浮窗平移(→T5)、§4.3 知识库(→T6)、§4.4 详情(→T7)、§4.5 背诵(→T8)、§4.6 providers(→T5)、§6 错误处理(→各页 error+重试)、§7 测试(→各任务)。
- **占位符扫描**：各任务代码块无 TBD/TODO;Task 8 揭晓答案的 summary 已给具体实现(`_reveal` 拉 `findById` + 失败回退标题),非占位。
- **类型一致性**：`ReviewSchedule`/`ReviewFeedback`/`SpacedRepetitionService.initial/apply`/`ReviewQueueItem`/`ReviewQueueRepository.dueQueue/todayNewQueue`/`ReviewScheduleRepository.getByTopic/upsert/findDue` 各任务间签名一致;`CategoryChild`/`TopicDetail`/`KnowledgeSearchResult`/`ReviewMode` 定义于 Task 5 providers 并被 Task 6-8 引用,均已给出完整定义。
