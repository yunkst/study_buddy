# 专注时钟与学习日报 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 study_buddy 增加手动计时的专注时钟（通知栏常驻实时计时 + 停止按钮）与按日期聚合的学习日报页（总用时 + 会话时间范围 + 当天接触的知识点列表）。

**Architecture:** 方案 A 三层分离——engine 加 v3 迁移（`focus_session` + `focus_session_topic` 表）与 `FocusSessionRepository`、`buildDailyReport` 聚合纯函数；`StudyScenario` 加可选 `onTopicTouched` 回调（专注会话进行中 AI 工具调用经此关联知识点）；Flutter `FocusSessionNotifier` 用 Stopwatch 计时并通过 MethodChannel `study_buddy/focus` 驱动 Android 前台服务通知栏；原生 `FocusTimerService` 每秒刷新通知 + 停止 Action 回传 Flutter。计时主源在 Flutter，原生只展示与转发停止意图。

**Tech Stack:** Dart 3 / Flutter / Riverpod 3 / go_router 14 / sqflite_common_ffi（engine 持久化）/ Android Kotlin 前台服务（通知栏）/ Material 3。

## Global Constraints

- engine 是纯 Dart 包，不依赖 Flutter；所有 engine 测试用 `sqflite_common_ffi` + `inMemoryDatabasePath` + `setUpAll(sqfliteFfiInit)`。
- engine 改动向后兼容：`onTopicTouched` 为可选参数默认 no-op；现有 34 个 engine 测试必须持续全绿，不得修改其断言。
- `kCurrentDbVersion` 从 2 升 3，`_v3` 只 `CREATE TABLE` + `CREATE INDEX`，禁止 DROP/ALTER 现有表。
- app 测试用 `ProviderContainer` + `overrideWith((ref) => ...)` 注入 fake，Riverpod 3 的 `Ref` 是 sealed 类不能 `implements`（见 `chat_session_provider_test.dart:11-13` 的 fake 模式）。
- 计时状态机只有 `idle → running → ended`，无 paused。
- 原生 MethodChannel 名 `study_buddy/focus`，方法：`start(sessionId)` / `stop()` / `isRunning()`；原生「停止」Action 通过 `onMethodCall` 反向调用 Flutter 的 `onStopped`。
- 通知权限：Android 13+（API 33）需运行时申请 `POST_NOTIFICATIONS`；前台服务类型用 `specialUse`（与现有 `OverlayService` 一致）。
- 所有代码注释与用户可见文案用中文（与现有代码一致）；类名/方法名用英文。
- 提交信息以 `feat:` / `test:` / `refactor:` / `chore:` 前缀，结尾加 `Co-Authored-By: Claude <noreply@anthropic.com>`。
- 工作目录为 worktree `D:\my_space\study\.claude\worktrees\worktree-focus-clock`，分支 `worktree-worktree-focus-clock`。

---

## File Structure

| 文件 | 职责 | 动作 |
|------|------|------|
| `packages/study_engine/lib/src/models/models.dart` | `FocusSession` / `FocusSessionTopic` 模型 + toMap/fromMap | 追加 |
| `packages/study_engine/lib/src/db/database_migrations.dart` | `kCurrentDbVersion`→3，`_v3` 建两张表 + 索引 | 修改 |
| `packages/study_engine/lib/src/repos/focus_session_repository.dart` | 会话 CRUD + 关联知识点 + 按日期查 | 新增 |
| `packages/study_engine/lib/src/aggregations/daily_report.dart` | `buildDailyReport` 聚合纯函数 + `DailyReport`/`DailyReportSession` | 新增 |
| `packages/study_engine/lib/src/agent/scenarios/study_scenario.dart` | 加可选 `onTopicTouched` 回调，save/update 成功后触发 | 修改 |
| `packages/study_engine/lib/study_engine.dart` | barrel 导出新增类型 | 修改 |
| `packages/study_engine/test/models_test.dart` | 新模型序列化测试 | 追加测试 |
| `packages/study_engine/test/db_test.dart` | v3 迁移测试 | 追加测试 |
| `packages/study_engine/test/focus_session_repository_test.dart` | Repository 测试 | 新增 |
| `packages/study_engine/test/daily_report_test.dart` | 聚合测试 | 新增 |
| `packages/study_engine/test/study_scenario_integration_test.dart` | `onTopicTouched` 回调测试 | 追加测试 |
| `study_buddy/lib/core/providers/focus_session_provider.dart` | `FocusSessionNotifier` 计时状态机 | 新增 |
| `study_buddy/lib/core/providers/focus_timer_bridge.dart` | `FocusTimerBridge` 原生通知栏桥接 | 新增 |
| `study_buddy/lib/core/providers/agent_session_provider.dart` | 注入 `onTopicTouched` | 修改 |
| `study_buddy/lib/features/focus/focus_page.dart` | 专注页 UI | 新增 |
| `study_buddy/lib/features/focus/daily_report_page.dart` | 日报页 UI | 新增 |
| `study_buddy/lib/router.dart` | 加 `/focus` `/daily-report` 路由 | 修改 |
| `study_buddy/lib/features/home/home_page.dart` | 加入口按钮 | 修改 |
| `study_buddy/test/core/providers/focus_session_provider_test.dart` | provider 状态机测试 | 新增 |
| `study_buddy/test/core/providers/focus_timer_bridge_test.dart` | 桥接契约测试 | 新增 |
| `study_buddy/test/features/focus/focus_page_test.dart` | 专注页 widget 测试 | 新增 |
| `study_buddy/test/features/focus/daily_report_page_test.dart` | 日报页 widget 测试 | 新增 |
| `study_buddy/android/.../FocusTimerService.kt` | 前台服务 + 通知 | 新增 |
| `study_buddy/android/.../FocusTimerPlugin.kt` | MethodChannel 桥接 | 新增 |
| `study_buddy/android/.../MainActivity.kt` | 注册 plugin | 修改 |
| `study_buddy/android/.../AndroidManifest.xml` | 声明 service + 权限 | 修改 |

---

### Task 1: FocusSession 与 FocusSessionTopic 模型

**Files:**
- Modify: `packages/study_engine/lib/src/models/models.dart`（文件末尾追加）
- Test: `packages/study_engine/test/models_test.dart`（追加测试组）

**Interfaces:**
- Consumes: 无（纯数据类）
- Produces: `FocusSession`（字段 `id?/startedAt/endedAt?/durationMs?`，`fromMap`/`toMap`）、`FocusSessionTopic`（字段 `id?/sessionId/topicId/linkedAt`，`fromMap`/`toMap`）。后续 Task 3/4 依赖这两个类。

- [ ] **Step 1: 写失败测试**

在 `packages/study_engine/test/models_test.dart` 末尾追加（若文件已有 `void main()` 则在内部加 `group`，否则新建 `main`；先 Read 文件确认结构）：

```dart
group('FocusSession', () {
  test('toMap 不含 id 时省略 id 键，进行中态 ended/duration 为 null', () {
    final s = FocusSession(startedAt: DateTime(2026, 8, 10, 9, 0, 0));
    final m = s.toMap();
    expect(m.containsKey('id'), isFalse);
    expect(m['started_at'], DateTime(2026, 8, 10, 9, 0, 0).millisecondsSinceEpoch);
    expect(m.containsKey('ended_at'), isFalse);
    expect(m.containsKey('duration_ms'), isFalse);
  });

  test('toMap 含 id 且已结束时写出全部字段', () {
    final s = FocusSession(
      id: 7,
      startedAt: DateTime(2026, 8, 10, 9, 0, 0),
      endedAt: DateTime(2026, 8, 10, 9, 30, 0),
      durationMs: 1800000,
    );
    final m = s.toMap();
    expect(m['id'], 7);
    expect(m['ended_at'], DateTime(2026, 8, 10, 9, 30, 0).millisecondsSinceEpoch);
    expect(m['duration_ms'], 1800000);
  });

  test('fromMap 往返一致（进行中态）', () {
    final s = FocusSession(
      id: 1,
      startedAt: DateTime(2026, 8, 10, 9, 0, 0),
    );
    final back = FocusSession.fromMap(s.toMap());
    expect(back.id, 1);
    expect(back.startedAt, s.startedAt);
    expect(back.endedAt, isNull);
    expect(back.durationMs, isNull);
  });

  test('fromMap 往返一致（已结束态）', () {
    final s = FocusSession(
      id: 2,
      startedAt: DateTime(2026, 8, 10, 9, 0, 0),
      endedAt: DateTime(2026, 8, 10, 10, 0, 0),
      durationMs: 3600000,
    );
    final back = FocusSession.fromMap(s.toMap());
    expect(back.endedAt, s.endedAt);
    expect(back.durationMs, 3600000);
  });
});

group('FocusSessionTopic', () {
  test('toMap/fromMap 往返一致', () {
    final t = FocusSessionTopic(
      id: 5,
      sessionId: 3,
      topicId: 11,
      linkedAt: DateTime(2026, 8, 10, 9, 5, 0),
    );
    final back = FocusSessionTopic.fromMap(t.toMap());
    expect(back.id, 5);
    expect(back.sessionId, 3);
    expect(back.topicId, 11);
    expect(back.linkedAt, DateTime(2026, 8, 10, 9, 5, 0));
  });

  test('toMap 不含 id 时省略 id 键', () {
    final t = FocusSessionTopic(
      sessionId: 3, topicId: 11, linkedAt: DateTime(2026, 8, 10, 9, 5, 0),
    );
    expect(t.toMap().containsKey('id'), isFalse);
  });
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd packages/study_engine && flutter test test/models_test.dart`
Expected: FAIL —— `FocusSession` / `FocusSessionTopic` 未定义（编译错误）。

- [ ] **Step 3: 实现模型**

在 `packages/study_engine/lib/src/models/models.dart` 文件末尾追加：

```dart
/// 一次专注学习会话。endedAt/durationMs 为 null 表示进行中。
class FocusSession {
  final int? id;
  final DateTime startedAt;
  final DateTime? endedAt;
  final int? durationMs;
  const FocusSession({
    this.id,
    required this.startedAt,
    this.endedAt,
    this.durationMs,
  });

  factory FocusSession.fromMap(Map<String, Object?> m) => FocusSession(
        id: m['id'] as int?,
        startedAt: DateTime.fromMillisecondsSinceEpoch(m['started_at'] as int),
        endedAt: m['ended_at'] != null
            ? DateTime.fromMillisecondsSinceEpoch(m['ended_at'] as int)
            : null,
        durationMs: m['duration_ms'] as int?,
      );
  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'started_at': startedAt.millisecondsSinceEpoch,
        if (endedAt != null) 'ended_at': endedAt!.millisecondsSinceEpoch,
        if (durationMs != null) 'duration_ms': durationMs,
      };
}

/// 专注会话与知识点的关联（多对多，不记时长）。UNIQUE(session_id, topic_id)。
class FocusSessionTopic {
  final int? id;
  final int sessionId;
  final int topicId;
  final DateTime linkedAt;
  const FocusSessionTopic({
    this.id,
    required this.sessionId,
    required this.topicId,
    required this.linkedAt,
  });

  factory FocusSessionTopic.fromMap(Map<String, Object?> m) => FocusSessionTopic(
        id: m['id'] as int?,
        sessionId: m['session_id'] as int,
        topicId: m['topic_id'] as int,
        linkedAt: DateTime.fromMillisecondsSinceEpoch(m['linked_at'] as int),
      );
  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'session_id': sessionId,
        'topic_id': topicId,
        'linked_at': linkedAt.millisecondsSinceEpoch,
      };
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd packages/study_engine && flutter test test/models_test.dart`
Expected: PASS（新增 6 个测试）。

- [ ] **Step 5: 跑全量回归确认无破坏**

Run: `cd packages/study_engine && flutter test`
Expected: PASS（原 34 + 新 6 = 40）。

- [ ] **Step 6: 提交**

```bash
git add packages/study_engine/lib/src/models/models.dart packages/study_engine/test/models_test.dart
git commit -m "feat(engine): FocusSession 与 FocusSessionTopic 模型

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 2: v3 数据库迁移（focus_session / focus_session_topic 表）

**Files:**
- Modify: `packages/study_engine/lib/src/db/database_migrations.dart`
- Test: `packages/study_engine/test/db_test.dart`（追加测试组）

**Interfaces:**
- Consumes: Task 1 的 `FocusSession`（测试中用于校验表结构可写入）
- Produces: `kCurrentDbVersion = 3`、`_v3` 创建 `focus_session`（`id/started_at/ended_at/duration_ms`）+ `focus_session_topic`（`id/session_id/topic_id/linked_at` + UNIQUE(session_id,topic_id)）+ 索引。Task 3 的 Repository 依赖这两张表。

- [ ] **Step 1: 写失败测试**

在 `packages/study_engine/test/db_test.dart` 的 `main()` 内追加（先 Read 确认现有结构）：

```dart
group('v3 专注时钟', () {
  late StudyDatabase sdb;
  setUpAll(sqfliteFfiInit);
  setUp(() async {
    sdb = await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
  });
  tearDown(() async => await sdb.close());

  test('建库后版本为 3', () async {
    expect(await sdb.db.getVersion(), 3);
  });

  test('focus_session 表存在且列结构正确', () async {
    final rows = await sdb.db.rawQuery('PRAGMA table_info(focus_session)');
    final cols = {for (final r in rows) r['name'] as String};
    expect(cols, containsAll(['id', 'started_at', 'ended_at', 'duration_ms']));
  });

  test('focus_session_topic 表存在且列结构正确', () async {
    final rows = await sdb.db.rawQuery('PRAGMA table_info(focus_session_topic)');
    final cols = {for (final r in rows) r['name'] as String};
    expect(cols, containsAll(['id', 'session_id', 'topic_id', 'linked_at']));
  });

  test('focus_session_topic 有 UNIQUE(session_id, topic_id)', () async {
    // 先建一个 category + topic 满足外键
    await sdb.db.insert('category', {'name': '数学', 'sort_order': 0, 'created_at': 0});
    final catId = (await sdb.db.query('category', limit: 1)).first['id'];
    await sdb.db.insert('topic', {
      'category_id': catId, 'question': 'q', 'title': 't1',
      'summary': 's', 'created_at': 0, 'updated_at': 0,
    });
    final topicId = (await sdb.db.query('topic', limit: 1)).first['id'];
    await sdb.db.insert('focus_session', {'started_at': 0});
    final sessionId = (await sdb.db.query('focus_session', limit: 1)).first['id'];

    await sdb.db.insert('focus_session_topic',
        {'session_id': sessionId, 'topic_id': topicId, 'linked_at': 0});
    // 重复插入应抛 UNIQUE
    expect(
      () => sdb.db.insert('focus_session_topic',
          {'session_id': sessionId, 'topic_id': topicId, 'linked_at': 1}),
      throwsA(predicate((e) => e.toString().contains('UNIQUE constraint failed'))),
    );
  });

  test('从 v2 升级到 v3 不丢失现有数据', () async {
    // 关闭刚才的 v3 库，手动建一个 v2 库再升级
    await sdb.close();
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          version: 2,
          onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON'),
          onCreate: (d, _) => migrateDatabase(d, 0, 2),
        ));
    // v2 库写一条 topic
    await db.insert('category', {'name': '物理', 'sort_order': 0, 'created_at': 0});
    final catId = (await db.query('category', limit: 1)).first['id'];
    await db.insert('topic', {
      'category_id': catId, 'question': 'q', 'title': '牛顿定律',
      'summary': 's', 'created_at': 0, 'updated_at': 0,
    });
    // 升级到 v3
    await migrateDatabase(db, 2, 3);
    // 旧数据还在
    final topics = await db.query('topic');
    expect(topics, hasLength(1));
    expect(topics.first['title'], '牛顿定律');
    // 新表可用
    await db.insert('focus_session', {'started_at': 0});
    expect((await db.query('focus_session')), hasLength(1));
    await db.close();
  });
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd packages/study_engine && flutter test test/db_test.dart`
Expected: FAIL —— `kCurrentDbVersion` 仍为 2，版本断言失败；`focus_session` 表不存在。

- [ ] **Step 3: 实现迁移**

修改 `packages/study_engine/lib/src/db/database_migrations.dart`：

```dart
const int kCurrentDbVersion = 3;
```

在 `migrateDatabase` 的 switch 增加 case 3：

```dart
      case 3:
        _v3(batch);
        break;
```

在文件末尾追加：

```dart
/// v3：专注时钟。新增 focus_session（会话）与 focus_session_topic（会话-知识点关联）。
/// 非破坏性：仅加表与索引，不动现有 v1/v2 表。
void _v3(Batch batch) {
  batch.execute('''
    CREATE TABLE focus_session (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      started_at INTEGER NOT NULL,
      ended_at INTEGER,
      duration_ms INTEGER
    )
  ''');
  batch.execute('CREATE INDEX idx_focus_session_started ON focus_session(started_at)');

  batch.execute('''
    CREATE TABLE focus_session_topic (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id INTEGER NOT NULL,
      topic_id INTEGER NOT NULL,
      linked_at INTEGER NOT NULL,
      FOREIGN KEY (session_id) REFERENCES focus_session(id) ON DELETE CASCADE,
      FOREIGN KEY (topic_id) REFERENCES topic(id) ON DELETE CASCADE,
      UNIQUE(session_id, topic_id)
    )
  ''');
  batch.execute('CREATE INDEX idx_fst_session ON focus_session_topic(session_id)');
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd packages/study_engine && flutter test test/db_test.dart`
Expected: PASS（新增 5 个测试）。

- [ ] **Step 5: 跑全量回归**

Run: `cd packages/study_engine && flutter test`
Expected: PASS。

- [ ] **Step 6: 提交**

```bash
git add packages/study_engine/lib/src/db/database_migrations.dart packages/study_engine/test/db_test.dart
git commit -m "feat(engine): v3 迁移——focus_session 与 focus_session_topic 表

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3: FocusSessionRepository

**Files:**
- Create: `packages/study_engine/lib/src/repos/focus_session_repository.dart`
- Test: `packages/study_engine/test/focus_session_repository_test.dart`

**Interfaces:**
- Consumes: Task 1 的 `FocusSession`/`FocusSessionTopic`、Task 2 的两张表、现有 `StudyDatabase`（构造注入，与 `MasteryRepository` 同模式）。
- Produces: `FocusSessionRepository`，方法签名：
  - `Future<int> start(DateTime startedAt)` —— 插入会话返回 id
  - `Future<void> end(int sessionId, DateTime endedAt, int durationMs)` —— 写结束字段
  - `Future<void> linkTopic(int sessionId, int topicId)` —— 关联知识点（UNIQUE 幂等，重复吞错）
  - `Future<List<FocusSession>> findByDate(DateTime dateLocal)` —— 按本地日期查当日全部会话（升序）
  - `Future<List<int>> topicIdsOf(int sessionId)` —— 某会话关联的 topicId 列表（按 linked_at 升序）
  - `Future<FocusSession?> findOpenSession()` —— 查 `ended_at IS NULL` 的孤儿会话（Task 8 孤儿清理用）

- [ ] **Step 1: 写失败测试**

创建 `packages/study_engine/test/focus_session_repository_test.dart`：

```dart
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';
import 'package:study_engine/study_engine.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  late StudyDatabase sdb;
  late FocusSessionRepository repo;
  late int topicId;

  setUp(() async {
    sdb = await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    repo = FocusSessionRepository(sdb);
    // 建一个 topic 供关联
    await sdb.db.insert('category', {'name': '数学', 'sort_order': 0, 'created_at': 0});
    final catId = (await sdb.db.query('category', limit: 1)).first['id'] as int;
    await sdb.db.insert('topic', {
      'category_id': catId, 'question': 'q', 'title': '极限',
      'summary': 's', 'created_at': 0, 'updated_at': 0,
    });
    topicId = (await sdb.db.query('topic', limit: 1)).first['id'] as int;
  });
  tearDown(() async => await sdb.close());

  test('start 插入会话并返回 id，endedAt/duration 为 null', () async {
    final id = await repo.start(DateTime(2026, 8, 10, 9, 0, 0));
    expect(id, greaterThan(0));
    final rows = await sdb.db.query('focus_session');
    expect(rows, hasLength(1));
    expect(rows.first['ended_at'], isNull);
    expect(rows.first['duration_ms'], isNull);
  });

  test('end 写入 ended_at 与 duration_ms', () async {
    final id = await repo.start(DateTime(2026, 8, 10, 9, 0, 0));
    await repo.end(id, DateTime(2026, 8, 10, 9, 30, 0), 1800000);
    final rows = await sdb.db.query('focus_session', where: 'id = ?', whereArgs: [id]);
    expect(rows.first['ended_at'], DateTime(2026, 8, 10, 9, 30, 0).millisecondsSinceEpoch);
    expect(rows.first['duration_ms'], 1800000);
  });

  test('linkTopic 关联知识点', () async {
    final id = await repo.start(DateTime(2026, 8, 10, 9, 0, 0));
    await repo.linkTopic(id, topicId);
    expect(await repo.topicIdsOf(id), [topicId]);
  });

  test('linkTopic 重复关联幂等（不抛错）', () async {
    final id = await repo.start(DateTime(2026, 8, 10, 9, 0, 0));
    await repo.linkTopic(id, topicId);
    await repo.linkTopic(id, topicId); // 不应抛
    expect(await repo.topicIdsOf(id), [topicId]); // 仍只一条
  });

  test('topicIdsOf 按 linked_at 升序', () async {
    // 建第二个 topic
    await sdb.db.insert('topic', {
      'category_id': (await sdb.db.query('category', limit: 1)).first['id'],
      'question': 'q2', 'title': '导数', 'summary': 's', 'created_at': 0, 'updated_at': 0,
    });
    final topicId2 = (await sdb.db.query('topic', where: 'title = ?', whereArgs: ['导数']))
        .first['id'] as int;
    final id = await repo.start(DateTime(2026, 8, 10, 9, 0, 0));
    await repo.linkTopic(id, topicId2); // 先关联导数
    await repo.linkTopic(id, topicId);  // 再关联极限
    expect(await repo.topicIdsOf(id), [topicId2, topicId]); // 按时间
  });

  test('findByDate 只返回当日起止区间内的会话（按 started_at 升序）', () async {
    // 前一天 23:30 开始
    await repo.start(DateTime(2026, 8, 9, 23, 30));
    // 当天 9:00 与 14:00
    final id1 = await repo.start(DateTime(2026, 8, 10, 9, 0));
    final id2 = await repo.start(DateTime(2026, 8, 10, 14, 0));
    // 次日 00:30
    await repo.start(DateTime(2026, 8, 11, 0, 30));

    final result = await repo.findByDate(DateTime(2026, 8, 10));
    expect(result.map((s) => s.id), [id1, id2]);
  });

  test('findOpenSession 返回未结束会话，无则 null', () async {
    expect(await repo.findOpenSession(), isNull);
    final id = await repo.start(DateTime(2026, 8, 10, 9, 0));
    final open = await repo.findOpenSession();
    expect(open?.id, id);
    await repo.end(id, DateTime(2026, 8, 10, 9, 30), 1800000);
    expect(await repo.findOpenSession(), isNull);
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd packages/study_engine && flutter test test/focus_session_repository_test.dart`
Expected: FAIL —— `FocusSessionRepository` 未定义。

- [ ] **Step 3: 实现 Repository**

创建 `packages/study_engine/lib/src/repos/focus_session_repository.dart`：

```dart
import '../db/database.dart';
import '../models/models.dart';

/// 专注会话仓储：会话生命周期 + 知识点关联 + 按日期查询。
class FocusSessionRepository {
  final StudyDatabase _db;
  FocusSessionRepository(this._db);

  /// 开始一次会话：插入 started_at，返回新 id。
  Future<int> start(DateTime startedAt) {
    return _db.db.insert('focus_session', FocusSession(startedAt: startedAt).toMap());
  }

  /// 结束会话：写入 ended_at 与 duration_ms。
  Future<void> end(int sessionId, DateTime endedAt, int durationMs) {
    return _db.db.update(
      'focus_session',
      {'ended_at': endedAt.millisecondsSinceEpoch, 'duration_ms': durationMs},
      where: 'id = ?',
      whereArgs: [sessionId],
    );
  }

  /// 关联知识点到会话。UNIQUE(session_id, topic_id) 保证幂等，重复关联被吞。
  Future<void> linkTopic(int sessionId, int topicId) async {
    try {
      await _db.db.insert(
        'focus_session_topic',
        FocusSessionTopic(
          sessionId: sessionId,
          topicId: topicId,
          linkedAt: DateTime.now(),
        ).toMap(),
      );
    } catch (e) {
      if (!e.toString().contains('UNIQUE constraint failed')) rethrow;
      // 幂等：已关联则忽略
    }
  }

  /// 查某日全部会话（按 started_at 升序）。dateLocal 取本地日期部分，
  /// 区间为 [当日0点, 次日0点)。
  Future<List<FocusSession>> findByDate(DateTime dateLocal) async {
    final start = DateTime(dateLocal.year, dateLocal.month, dateLocal.day)
        .millisecondsSinceEpoch;
    final end = DateTime(dateLocal.year, dateLocal.month, dateLocal.day + 1)
        .millisecondsSinceEpoch;
    final rows = await _db.db.query(
      'focus_session',
      where: 'started_at >= ? AND started_at < ?',
      whereArgs: [start, end],
      orderBy: 'started_at ASC',
    );
    return rows.map(FocusSession.fromMap).toList();
  }

  /// 某会话关联的知识点 id 列表（按 linked_at 升序）。
  Future<List<int>> topicIdsOf(int sessionId) async {
    final rows = await _db.db.query(
      'focus_session_topic',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'linked_at ASC',
    );
    return rows.map((r) => r['topic_id'] as int).toList();
  }

  /// 查未结束的孤儿会话（ended_at IS NULL）。无则 null。
  /// 用于 app 启动时清理崩溃残留（见 FocusSessionNotifier 恢复逻辑）。
  Future<FocusSession?> findOpenSession() async {
    final rows = await _db.db.query(
      'focus_session',
      where: 'ended_at IS NULL',
      orderBy: 'started_at DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : FocusSession.fromMap(rows.first);
  }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd packages/study_engine && flutter test test/focus_session_repository_test.dart`
Expected: PASS（7 个测试）。

- [ ] **Step 5: 跑全量回归**

Run: `cd packages/study_engine && flutter test`
Expected: PASS。

- [ ] **Step 6: 提交**

```bash
git add packages/study_engine/lib/src/repos/focus_session_repository.dart packages/study_engine/test/focus_session_repository_test.dart
git commit -m "feat(engine): FocusSessionRepository 会话CRUD+知识点关联+按日期查

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 4: buildDailyReport 聚合纯函数

**Files:**
- Create: `packages/study_engine/lib/src/aggregations/daily_report.dart`
- Test: `packages/study_engine/test/daily_report_test.dart`

**Interfaces:**
- Consumes: Task 3 的 `FocusSessionRepository`、现有 `TopicRepository`（`findById`）
- Produces:
  - `DailyReportSession`（字段 `FocusSession session`、`List<Topic> topics`）
  - `DailyReport`（字段 `DateTime date`、`List<DailyReportSession> sessions`；getter `totalDurationMs`、`uniqueTopics`）
  - `Future<DailyReport> buildDailyReport({required FocusSessionRepository focusRepo, required TopicRepository topicRepo, required DateTime date})`

- [ ] **Step 1: 写失败测试**

创建 `packages/study_engine/test/daily_report_test.dart`：

```dart
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';
import 'package:study_engine/study_engine.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  late StudyDatabase sdb;
  late FocusSessionRepository focusRepo;
  late TopicRepository topicRepo;
  late int t1, t2;

  setUp(() async {
    sdb = await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    focusRepo = FocusSessionRepository(sdb);
    topicRepo = TopicRepository(sdb);
    final cats = CategoryRepository(sdb);
    final catId = await cats.ensurePath(['数学']);
    final now = DateTime(2026, 8, 10);
    t1 = await topicRepo.insert(Topic(
      categoryId: catId, question: 'q1', title: '极限', summary: 's1',
      createdAt: now, updatedAt: now,
    ));
    t2 = await topicRepo.insert(Topic(
      categoryId: catId, question: 'q2', title: '导数', summary: 's2',
      createdAt: now, updatedAt: now,
    ));
  });
  tearDown(() async => await sdb.close());

  test('空日报：无会话时 totalDuration 为 0、topics 为空', () async {
    final report = await buildDailyReport(
      focusRepo: focusRepo, topicRepo: topicRepo, date: DateTime(2026, 8, 10));
    expect(report.sessions, isEmpty);
    expect(report.totalDurationMs, 0);
    expect(report.uniqueTopics, isEmpty);
  });

  test('单会话：聚合 duration 与关联知识点', () async {
    final id = await focusRepo.start(DateTime(2026, 8, 10, 9, 0));
    await focusRepo.end(id, DateTime(2026, 8, 10, 9, 30), 1800000);
    await focusRepo.linkTopic(id, t1);

    final report = await buildDailyReport(
      focusRepo: focusRepo, topicRepo: topicRepo, date: DateTime(2026, 8, 10));
    expect(report.sessions, hasLength(1));
    expect(report.totalDurationMs, 1800000);
    expect(report.sessions.first.topics.map((t) => t.title), ['极限']);
    expect(report.uniqueTopics.map((t) => t.title), ['极限']);
  });

  test('多会话：totalDuration 累加、知识点跨会话去重保序', () async {
    final id1 = await focusRepo.start(DateTime(2026, 8, 10, 9, 0));
    await focusRepo.end(id1, DateTime(2026, 8, 10, 9, 30), 1800000);
    await focusRepo.linkTopic(id1, t1);
    await focusRepo.linkTopic(id1, t2);

    final id2 = await focusRepo.start(DateTime(2026, 8, 10, 14, 0));
    await focusRepo.end(id2, DateTime(2026, 8, 10, 15, 0), 3600000);
    await focusRepo.linkTopic(id2, t1); // 重复关联 t1，应去重

    final report = await buildDailyReport(
      focusRepo: focusRepo, topicRepo: topicRepo, date: DateTime(2026, 8, 10));
    expect(report.sessions, hasLength(2));
    expect(report.totalDurationMs, 5400000); // 1800000 + 3600000
    // uniqueTopics 去重，保首次出现顺序：t1, t2
    expect(report.uniqueTopics.map((t) => t.title), ['极限', '导数']);
  });

  test('跨午夜会话归入开始日', () async {
    // 8月10日 23:00 开始，8月11日 01:00 结束
    final id = await focusRepo.start(DateTime(2026, 8, 10, 23, 0));
    await focusRepo.end(id, DateTime(2026, 8, 11, 1, 0), 7200000);
    await focusRepo.linkTopic(id, t1);

    final report10 = await buildDailyReport(
      focusRepo: focusRepo, topicRepo: topicRepo, date: DateTime(2026, 8, 10));
    final report11 = await buildDailyReport(
      focusRepo: focusRepo, topicRepo: topicRepo, date: DateTime(2026, 8, 11));
    expect(report10.sessions, hasLength(1)); // 归入 10 日
    expect(report10.totalDurationMs, 7200000);
    expect(report11.sessions, isEmpty);
  });

  test('会话含已删除知识点：topics 跳过不存在的', () async {
    final id = await focusRepo.start(DateTime(2026, 8, 10, 9, 0));
    await focusRepo.end(id, DateTime(2026, 8, 10, 9, 30), 1800000);
    await focusRepo.linkTopic(id, t1);
    await focusRepo.linkTopic(id, 99999); // 不存在的 topicId

    final report = await buildDailyReport(
      focusRepo: focusRepo, topicRepo: topicRepo, date: DateTime(2026, 8, 10));
    expect(report.sessions.first.topics, hasLength(1)); // 只剩存在的
    expect(report.sessions.first.topics.first.title, '极限');
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd packages/study_engine && flutter test test/daily_report_test.dart`
Expected: FAIL —— `buildDailyReport` / `DailyReport` 未定义。

- [ ] **Step 3: 实现聚合**

创建 `packages/study_engine/lib/src/aggregations/daily_report.dart`：

```dart
import '../models/models.dart';
import '../repos/focus_session_repository.dart';
import '../repos/topic_repository.dart';

/// 日报中一个会话的展示项：会话本身 + 该会话关联的知识点详情。
class DailyReportSession {
  final FocusSession session;
  final List<Topic> topics;
  const DailyReportSession(this.session, this.topics);
}

/// 日报聚合结果。
class DailyReport {
  final DateTime date;
  final List<DailyReportSession> sessions;
  const DailyReport(this.date, this.sessions);

  /// 当天总专注用时（毫秒）。进行中会话（durationMs 为 null）计 0。
  int get totalDurationMs =>
      sessions.fold(0, (sum, s) => sum + (s.session.durationMs ?? 0));

  /// 当天接触的全部知识点（去重，保持首次出现顺序）。
  List<Topic> get uniqueTopics {
    final seen = <int>{};
    final result = <Topic>[];
    for (final s in sessions) {
      for (final t in s.topics) {
        if (t.id != null && seen.add(t.id!)) result.add(t);
      }
    }
    return result;
  }
}

/// 按日期聚合日报。纯函数无副作用：只读 Repository。
///
/// 会话按 [FocusSessionRepository.findByDate] 的 started_at 升序返回；
/// 每个会话关联的知识点按 linked_at 升序，跳过已删除的 topic。
Future<DailyReport> buildDailyReport({
  required FocusSessionRepository focusRepo,
  required TopicRepository topicRepo,
  required DateTime date,
}) async {
  final sessions = await focusRepo.findByDate(date);
  final reportSessions = <DailyReportSession>[];
  for (final s in sessions) {
    final topicIds = await focusRepo.topicIdsOf(s.id!);
    final topics = <Topic>[];
    for (final id in topicIds) {
      final t = await topicRepo.findById(id);
      if (t != null) topics.add(t);
    }
    reportSessions.add(DailyReportSession(s, topics));
  }
  return DailyReport(date, reportSessions);
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd packages/study_engine && flutter test test/daily_report_test.dart`
Expected: PASS（5 个测试）。

- [ ] **Step 5: 跑全量回归**

Run: `cd packages/study_engine && flutter test`
Expected: PASS。

- [ ] **Step 6: 提交**

```bash
git add packages/study_engine/lib/src/aggregations/daily_report.dart packages/study_engine/test/daily_report_test.dart
git commit -m "feat(engine): buildDailyReport 按日期聚合总用时/会话/知识点

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 5: StudyScenario 加 onTopicTouched 回调

**Files:**
- Modify: `packages/study_engine/lib/src/agent/scenarios/study_scenario.dart`
- Test: `packages/study_engine/test/study_scenario_integration_test.dart`（追加测试组）

**Interfaces:**
- Consumes: 现有 `StudyScenario` 构造与 `_saveTopic`/`_updateTopic` 内部方法
- Produces: `StudyScenario` 增加可选参数 `Future<void> Function(int topicId)? onTopicTouched`（默认 null = no-op）。在 `_saveTopic` 成功插入后、`_updateTopic` 成功更新后，以新/已存在的 topicId 触发。Task 9 的 `agent_session_provider` 会注入实现。

**关键设计**：回调签名是 `Future<void> Function(int topicId)?`。`_saveTopic` 命中已存在时也算"接触"该知识点（以 existing.id 触发），因为用户确实在学它。

- [ ] **Step 1: 写失败测试**

在 `packages/study_engine/test/study_scenario_integration_test.dart` 的 `main()` 末尾追加（在 `_ScriptedLlm` 类定义之前）：

```dart
  group('onTopicTouched 回调', () {
    test('save_topic 新建成功后触发回调(新 topicId)', () async {
      final sdb = await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
      final touched = <int>[];
      final scenario = StudyScenario(
        categories: CategoryRepository(sdb),
        topics: TopicRepository(sdb),
        edges: TopicEdgeRepository(sdb),
        memories: AgentMemoryRepository(sdb),
        onTopicTouched: (id) async => touched.add(id),
      );

      await scenario.executeTool('save_topic', {
        'path': '数学', 'title': '极限', 'question': 'q', 'summary': 's',
      });
      expect(touched, hasLength(1));
      final topics = TopicRepository(sdb);
      final t = await topics.findByTitle('极限');
      expect(touched.first, t!.id);
      await sdb.close();
    });

    test('save_topic 命中已存在也触发回调(existing.id)', () async {
      final sdb = await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
      final touched = <int>[];
      final scenario = StudyScenario(
        categories: CategoryRepository(sdb),
        topics: TopicRepository(sdb),
        edges: TopicEdgeRepository(sdb),
        memories: AgentMemoryRepository(sdb),
        onTopicTouched: (id) async => touched.add(id),
      );
      // 第一次新建
      await scenario.executeTool('save_topic', {
        'path': '数学', 'title': '极限', 'question': 'q', 'summary': 's',
      });
      touched.clear();
      // 第二次重复（命中已存在）
      await scenario.executeTool('save_topic', {
        'path': '物理', 'title': '极限', 'question': 'q2', 'summary': 's2',
      });
      expect(touched, hasLength(1));
      await sdb.close();
    });

    test('update_topic 成功后触发回调', () async {
      final sdb = await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
      final touched = <int>[];
      final scenario = StudyScenario(
        categories: CategoryRepository(sdb),
        topics: TopicRepository(sdb),
        edges: TopicEdgeRepository(sdb),
        memories: AgentMemoryRepository(sdb),
        onTopicTouched: (id) async => touched.add(id),
      );
      await scenario.executeTool('save_topic', {
        'path': '数学', 'title': '极限', 'question': 'q', 'summary': '旧',
      });
      final t = await TopicRepository(sdb).findByTitle('极限');
      touched.clear();
      await scenario.executeTool('update_topic', {'id': t!.id, 'summary': '新答案'});
      expect(touched, [t.id]);
      await sdb.close();
    });

    test('未设置回调时 no-op，不影响现有行为', () async {
      final sdb = await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
      final scenario = StudyScenario(
        categories: CategoryRepository(sdb),
        topics: TopicRepository(sdb),
        edges: TopicEdgeRepository(sdb),
        memories: AgentMemoryRepository(sdb),
        // 不传 onTopicTouched
      );
      final result = await scenario.executeTool('save_topic', {
        'path': '数学', 'title': '极限', 'question': 'q', 'summary': 's',
      });
      expect(result, contains('已保存'));
      await sdb.close();
    });
  });
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd packages/study_engine && flutter test test/study_scenario_integration_test.dart`
Expected: FAIL —— `StudyScenario` 构造不接受 `onTopicTouched` 参数（编译错误）。

- [ ] **Step 3: 实现 onTopicTouched**

修改 `packages/study_engine/lib/src/agent/scenarios/study_scenario.dart`。先在类字段与构造函数加参数（参照现有字段位置）：

```dart
class StudyScenario implements AgentScenario {
  final CategoryRepository categories;
  final TopicRepository topics;
  final TopicEdgeRepository edges;
  final AgentMemoryRepository memories;

  /// 知识点被接触时的回调（save_topic 新建/命中已存在、update_topic 成功）。
  /// 默认 null = no-op。app 层注入实现以关联到当前专注会话。
  final Future<void> Function(int topicId)? onTopicTouched;

  StudyScenario({
    required this.categories,
    required this.topics,
    required this.edges,
    required this.memories,
    this.onTopicTouched,
  });
```

然后改 `_saveTopic`：在两处「已存在」return 之前、以及成功 insert 之后触发回调。完整替换 `_saveTopic` 方法：

```dart
  Future<String> _saveTopic(String path, String title, String question, String summary) async {
    final existing = await topics.findByTitle(title);
    if (existing != null) {
      await onTopicTouched?.call(existing.id!);
      return '知识点「$title」已存在(id=${existing.id})。如需补充答案请用 update_topic(id=${existing.id}, summary=...)';
    }
    final segments = path.split('/').where((s) => s.trim().isNotEmpty).toList();
    if (segments.isEmpty) return 'path 不能为空';
    final catId = await categories.ensurePath(segments);
    final now = DateTime.now();
    int id;
    try {
      id = await topics.insert(Topic(
        categoryId: catId,
        question: question,
        title: title,
        summary: summary,
        createdAt: now,
        updatedAt: now,
      ));
    } catch (e) {
      // 并发兜底：findByTitle 与 insert 非原子，并发下另一会话可能已插入同 title，
      // 触发 UNIQUE 冲突。捕获后转「已存在」引导（与上面 findByTitle 命中一致），
      // 非 UNIQUE 异常继续抛出。
      if (e.toString().contains('UNIQUE constraint failed')) {
        final existing = await topics.findByTitle(title);
        await onTopicTouched?.call(existing!.id!);
        return '知识点「$title」已存在(id=${existing.id})。如需补充答案请用 update_topic(id=${existing.id}, summary=...)';
      }
      rethrow;
    }
    await onTopicTouched?.call(id);
    return '已保存知识点「$title」(id=$id)，路径 $path';
  }
```

再改 `_updateTopic`，在 `updateSummary` 成功后触发：

```dart
  Future<String> _updateTopic(int id, String summary) async {
    final existing = await topics.findById(id);
    if (existing == null) return '知识点 id=$id 不存在';
    await topics.updateSummary(id, summary);
    await onTopicTouched?.call(id);
    return '已更新知识点「${existing.title}」的答案';
  }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd packages/study_engine && flutter test test/study_scenario_integration_test.dart`
Expected: PASS（原 6 + 新 4 = 10 个测试）。

- [ ] **Step 5: 跑全量回归（确认现有 6 场景测试未受影响）**

Run: `cd packages/study_engine && flutter test`
Expected: PASS。

- [ ] **Step 6: 提交**

```bash
git add packages/study_engine/lib/src/agent/scenarios/study_scenario.dart packages/study_engine/test/study_scenario_integration_test.dart
git commit -m "feat(engine): StudyScenario 加可选 onTopicTouched 回调

save_topic 新建/命中已存在、update_topic 成功后触发，默认 no-op 向后兼容。

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 6: engine barrel 导出

**Files:**
- Modify: `packages/study_engine/lib/study_engine.dart`

**Interfaces:**
- Consumes: Task 1/3/4/5 的新类型
- Produces: barrel 导出 `FocusSession`、`FocusSessionTopic`、`FocusSessionRepository`、`DailyReport`、`DailyReportSession`、`buildDailyReport`。app 层（Task 7+）通过 `package:study_engine/study_engine.dart` 引用。

- [ ] **Step 1: 追加导出**

在 `packages/study_engine/lib/study_engine.dart` 末尾追加（先 Read 确认现有导出顺序，保持 repos 导出在一起）：

```dart
export 'src/repos/focus_session_repository.dart';
export 'src/aggregations/daily_report.dart';
```

注：`FocusSession`/`FocusSessionTopic` 已包含在 `export 'src/models/models.dart';` 中，无需单独导出。

- [ ] **Step 2: 验证 app 层能引用**

Run（在 study_buddy 目录，验证编译）:
```bash
cd study_buddy && flutter analyze lib 2>&1 | tail -5
```
Expected: 无错误（此时 app 还没用，仅验证 barrel 不破坏编译）。

- [ ] **Step 3: 跑 engine 全量回归**

Run: `cd packages/study_engine && flutter test`
Expected: PASS。

- [ ] **Step 4: 提交**

```bash
git add packages/study_engine/lib/study_engine.dart
git commit -m "feat(engine): barrel 导出 FocusSessionRepository 与 buildDailyReport

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 7: FocusTimerBridge 原生通知栏桥接（Flutter 侧）

**Files:**
- Create: `study_buddy/lib/core/providers/focus_timer_bridge.dart`
- Test: `study_buddy/test/core/providers/focus_timer_bridge_test.dart`

**Interfaces:**
- Consumes: `package:flutter/services.dart` 的 `MethodChannel`
- Produces: `FocusTimerBridge` 类：
  - `Future<void> start(int sessionId)` —— 通知原生启动前台服务
  - `Future<void> stop()` —— 通知原生停止前台服务
  - `Future<bool> isRunning()` —— 查原生服务是否在跑
  - `void setOnStopped(void Function() cb)` —— 注册原生「停止」按钮回调
  - `Future<void> handleMethodCall(MethodCall call)` —— 供测试注入的 handler（生产由 plugin 内部 setMethodCallHandler 注册）
- MethodChannel 名 `study_buddy/focus`；原生→Flutter 的反向调用方法名为 `onStopped`（无参）。
- 生产 provider：`final focusTimerBridgeProvider = Provider<FocusTimerBridge>((ref) => FocusTimerBridge());`

**测试策略**：用 `TestDefaultBinaryMessengerBinding` mock channel（参照 `study_buddy/test/screenshot_provider_test.dart` 的 channel mock 模式）。先 Read 该文件确认 mock 写法。

- [ ] **Step 1: 先 Read 参考测试**

Read `study_buddy/test/screenshot_provider_test.dart` 全文，确认 `TestDefaultBinaryMessengerBinding` + `ServicesBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler` 的用法与 tearDown 清理。

- [ ] **Step 2: 写失败测试**

创建 `study_buddy/test/core/providers/focus_timer_bridge_test.dart`：

```dart
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:study_buddy/core/providers/focus_timer_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('study_buddy/focus');
  late List<MethodCall> calls;
  late FocusTimerBridge bridge;

  setUp(() {
    calls = [];
    bridge = FocusTimerBridge();
    ServicesBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (call) async {
        calls.add(call);
        if (call.method == 'isRunning') return false;
        return null;
      },
    );
  });
  tearDown(() {
    ServicesBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  test('start 调用原生 start 并传 sessionId', () async {
    await bridge.start(42);
    expect(calls, hasLength(1));
    expect(calls.first.method, 'start');
    expect(calls.first.arguments, 42);
  });

  test('stop 调用原生 stop', () async {
    await bridge.stop();
    expect(calls.single.method, 'stop');
  });

  test('isRunning 返回原生布尔值', () async {
    final running = await bridge.isRunning();
    expect(running, isFalse);
  });

  test('setOnStopped 注册的回调在原生反向调用 onStopped 时触发', () async {
    var stopped = false;
    bridge.setOnStopped(() => stopped = true);
    // 模拟原生反向调用 Flutter
    await ServicesBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(const MethodCall('onStopped')),
      (data) {},
    );
    expect(stopped, isTrue);
  });
}
```

- [ ] **Step 3: 跑测试确认失败**

Run: `cd study_buddy && flutter test test/core/providers/focus_timer_bridge_test.dart`
Expected: FAIL —— `FocusTimerBridge` 未定义。

- [ ] **Step 4: 实现 Bridge**

创建 `study_buddy/lib/core/providers/focus_timer_bridge.dart`：

```dart
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 专注计时通知栏的 Flutter↔原生桥接。
///
/// MethodChannel("study_buddy/focus")：
/// - start(sessionId) / stop() / isRunning() —— Flutter→原生
/// - onStopped —— 原生→Flutter（用户点了通知栏「停止」按钮）
///
/// 计时主源在 Flutter（FocusSessionNotifier），原生只负责展示通知与转发停止意图。
class FocusTimerBridge {
  static const _channel = MethodChannel('study_buddy/focus');

  void Function()? _onStopped;

  FocusTimerBridge() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onStopped') {
        _onStopped?.call();
      }
      return null;
    });
  }

  /// 启动原生前台服务（通知栏常驻计时）。
  Future<void> start(int sessionId) {
    return _channel.invokeMethod<void>('start', sessionId);
  }

  /// 停止原生前台服务（取消通知）。
  Future<void> stop() {
    return _channel.invokeMethod<void>('stop');
  }

  /// 原生服务是否仍在运行。
  Future<bool> isRunning() async {
    final result = await _channel.invokeMethod<bool>('isRunning');
    return result ?? false;
  }

  /// 注册「用户从通知栏停止」回调。
  void setOnStopped(void Function() cb) {
    _onStopped = cb;
  }
}

final focusTimerBridgeProvider = Provider<FocusTimerBridge>((ref) {
  return FocusTimerBridge();
});
```

- [ ] **Step 5: 跑测试确认通过**

Run: `cd study_buddy && flutter test test/core/providers/focus_timer_bridge_test.dart`
Expected: PASS（4 个测试）。

注：若 `setOnStopped` 测试因 `setMethodCallHandler` 与 mock 冲突失败，可在测试 setUp 中先 `FocusTimerBridge()` 构造再 setMock——构造函数里已 setMethodCallHandler，mock handler 会在构造时被覆盖。若遇到此问题，把 bridge 构造放到 setMock 之前，并让构造内的 setMethodCallHandler 与 mock 共存（mock 只拦截 Flutter→原生方向，构造内的 handler 处理原生→Flutter 方向，二者不冲突）。

- [ ] **Step 6: 跑 app 全量回归**

Run: `cd study_buddy && flutter test`
Expected: PASS（原 44 + 新 4）。

- [ ] **Step 7: 提交**

```bash
git add study_buddy/lib/core/providers/focus_timer_bridge.dart study_buddy/test/core/providers/focus_timer_bridge_test.dart
git commit -m "feat(app): FocusTimerBridge 通知栏原生桥接

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 8: FocusSessionNotifier 计时状态机

**Files:**
- Create: `study_buddy/lib/core/providers/focus_session_provider.dart`
- Test: `study_buddy/test/core/providers/focus_session_provider_test.dart`

**Interfaces:**
- Consumes:
  - `databaseProvider`（FutureProvider<StudyDatabase>，现有）
  - `focusTimerBridgeProvider`（Task 7）
  - `FocusSessionRepository`（Task 3，从 `study_engine` 导出）
- Produces:
  - `FocusSessionState`（不可变，字段 `int? sessionId`、`DateTime? startedAt`、`Duration elapsed`、`bool running`；静态 `idle`）
  - `FocusSessionNotifier extends StateNotifier<FocusSessionState>`：
    - `Future<void> start()` —— DB 插入会话→启动原生服务→Stopwatch+tick
    - `Future<void> stop()` —— 停 Stopwatch→DB 结束会话→停原生服务→清 sessionId
    - `Future<void> recoverOrphan()` —— 启动时调用：查原生 isRunning + DB findOpenSession，恢复或清理
    - `dispose()` —— 取消 tick
  - `final focusSessionProvider = StateNotifierProvider<FocusSessionNotifier, FocusSessionState>((ref) => ...)`
- 状态守卫：`start()` 检测 `state.running` 直接 return；`stop()` 检测 `!state.running` 直接 return（处理通知栏停 + app 内停竞态）。
- 计时驱动：`Stream.periodic(Duration(seconds: 1))`，每秒 `state = state.copyWith(elapsed: _stopwatch.elapsed)`。

- [ ] **Step 1: 写失败测试**

创建 `study_buddy/test/core/providers/focus_session_provider_test.dart`：

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:study_buddy/core/providers/focus_session_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('初始状态为 idle', () {
    final container = ProviderContainer(overrides: [
      // 用假 databaseProvider + focusTimerBridgeProvider，见下方 fake
    ]);
    addTearDown(container.dispose);
    final state = container.read(focusSessionProvider);
    expect(state.running, isFalse);
    expect(state.sessionId, isNull);
    expect(state.elapsed, Duration.zero);
  });

  // 后续测试用 fake DB（内存 sqlite）+ fake bridge，
  // 验证 start→running、stop→idle+落库、重复 start 拦截、recoverOrphan。
  // 详见 Step 3 的实现细节，测试在此处补全。
}
```

注：`FocusSessionNotifier` 依赖 `databaseProvider`（async）与 `focusTimerBridgeProvider`（原生 channel）。测试需 override 这两个：DB 用 `sqflite_common_ffi` 内存库（在 app 测试中需 `sqfliteFfiInit`），bridge 用一个 fake 类记录调用。完整测试在 Step 3 实现后补全。

- [ ] **Step 2: 跑测试确认失败**

Run: `cd study_buddy && flutter test test/core/providers/focus_session_provider_test.dart`
Expected: FAIL —— `FocusSessionState` / `focusSessionProvider` 未定义。

- [ ] **Step 3: 实现状态机**

创建 `study_buddy/lib/core/providers/focus_session_provider.dart`：

```dart
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:study_engine/study_engine.dart';

import 'database_provider.dart';
import 'focus_timer_bridge.dart';

/// 专注会话状态。running=false 即 idle（无进行中会话）。
class FocusSessionState {
  final int? sessionId;
  final DateTime? startedAt;
  final Duration elapsed;
  final bool running;
  const FocusSessionState({
    this.sessionId,
    this.startedAt,
    this.elapsed = Duration.zero,
    this.running = false,
  });
  static const idle = FocusSessionState();

  FocusSessionState copyWith({
    int? sessionId,
    DateTime? startedAt,
    Duration? elapsed,
    bool? running,
    bool clearSession = false,
  }) =>
      FocusSessionState(
        sessionId: clearSession ? null : (sessionId ?? this.sessionId),
        startedAt: clearSession ? null : (startedAt ?? this.startedAt),
        elapsed: elapsed ?? this.elapsed,
        running: running ?? this.running,
      );
}

/// 专注计时状态机。计时主源在本 Notifier（Stopwatch），原生通知栏为镜像。
class FocusSessionNotifier extends StateNotifier<FocusSessionState> {
  FocusSessionNotifier(this._ref) : super(FocusSessionState.idle);
  final Ref _ref;
  Stopwatch? _stopwatch;
  StreamSubscription<Duration>? _tick;

  /// 开始专注。守卫：已在 running 态直接 return。
  Future<void> start() async {
    if (state.running) return;
    final db = await _ref.read(databaseProvider.future);
    final repo = FocusSessionRepository(db);
    final now = DateTime.now();
    final id = await repo.start(now);

    final bridge = _ref.read(focusTimerBridgeProvider);
    try {
      await bridge.start(id);
    } catch (_) {
      // 通知栏启动失败不阻断计时（降级：app 内仍计时）
    }

    _stopwatch = Stopwatch()..start();
    state = FocusSessionState(
      sessionId: id,
      startedAt: now,
      elapsed: Duration.zero,
      running: true,
    );
    _tick = Stream.periodic(const Duration(seconds: 1), (_) => _stopwatch!.elapsed)
        .listen((e) {
      if (mounted) state = state.copyWith(elapsed: e);
    });
  }

  /// 结束专注。守卫：非 running 态直接 return（处理通知栏+app 内竞态）。
  Future<void> stop() async {
    if (!state.running) return;
    _tick?.cancel();
    _tick = null;
    _stopwatch?.stop();
    final elapsed = _stopwatch?.elapsed ?? Duration.zero;
    _stopwatch = null;

    final sessionId = state.sessionId;
    if (sessionId != null) {
      final db = await _ref.read(databaseProvider.future);
      final repo = FocusSessionRepository(db);
      await repo.end(sessionId, DateTime.now(), elapsed.inMilliseconds);
    }

    final bridge = _ref.read(focusTimerBridgeProvider);
    try {
      await bridge.stop();
    } catch (_) {
      // 通知栏取消失败不阻断
    }

    state = FocusSessionState.idle;
  }

  /// 启动时调用：恢复或清理孤儿会话。
  /// - 原生仍在跑 + DB 有未结束会话 → 恢复 running（Stopwatch 从 startedAt 重算）
  /// - 原生未跑 + DB 有未结束会话 → 视为崩溃残留，补结束
  Future<void> recoverOrphan() async {
    if (state.running) return;
    final db = await _ref.read(databaseProvider.future);
    final repo = FocusSessionRepository(db);
    final open = await repo.findOpenSession();
    if (open == null) return;

    final bridge = _ref.read(focusTimerBridgeProvider);
    final nativeRunning = await bridge.isRunning();

    if (nativeRunning) {
      // 恢复：从 startedAt 重算 elapsed
      _stopwatch = Stopwatch()
        ..start();
      // Stopwatch 无法设初始值，用 startedAt 差值在 tick 里算
      final offset = DateTime.now().difference(open.startedAt);
      state = FocusSessionState(
        sessionId: open.id,
        startedAt: open.startedAt,
        elapsed: offset,
        running: true,
      );
      _tick = Stream.periodic(const Duration(seconds: 1), (_) {
        // elapsed = 初始 offset + stopwatch 增量
        return offset + (_stopwatch?.elapsed ?? Duration.zero);
      }).listen((e) {
        if (mounted) state = state.copyWith(elapsed: e);
      });
    } else {
      // 清理：补结束
      final elapsed = DateTime.now().difference(open.startedAt);
      await repo.end(open.id!, DateTime.now(), elapsed.inMilliseconds);
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }
}

final focusSessionProvider =
    StateNotifierProvider<FocusSessionNotifier, FocusSessionState>((ref) {
  return FocusSessionNotifier(ref);
});
```

- [ ] **Step 4: 补全测试**

补全 `study_buddy/test/core/providers/focus_session_provider_test.dart`（用内存 sqlite + fake bridge）。需要 fake `FocusTimerBridge`：因其方法非虚且构造时 setMethodCallHandler，测试中用 `focusTimerBridgeProvider.overrideWith` 提供一个不触发真实 channel 的实例——但 `FocusTimerBridge` 构造会 setMethodCallHandler。**最简方案**：测试中不 override bridge，而是用 mock channel 拦截 `study_buddy/focus`（参照 Task 7 的 mock 模式），让真实 `FocusTimerBridge` 跑通。补全测试：

```dart
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:study_buddy/core/providers/database_provider.dart';
import 'package:study_buddy/core/providers/focus_session_provider.dart';
import 'package:study_engine/study_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  late StudyDatabase sdb;
  const channel = MethodChannel('study_buddy/focus');
  late List<MethodCall> bridgeCalls;

  setUp(() async {
    sdb = await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    bridgeCalls = [];
    ServicesBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (call) async {
        bridgeCalls.add(call);
        if (call.method == 'isRunning') return false;
        return null;
      },
    );
  });
  tearDown(() async {
    ServicesBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    await sdb.close();
  });

  ProviderContainer makeContainer() {
    final c = ProviderContainer(overrides: [
      databaseProvider.overrideWith((ref) async {
        ref.onDispose(() => sdb.close());
        return sdb;
      }),
    ]);
    addTearDown(c.dispose);
    return c;
  }

  test('初始状态为 idle', () {
    final container = makeContainer();
    final state = container.read(focusSessionProvider);
    expect(state.running, isFalse);
    expect(state.sessionId, isNull);
    expect(state.elapsed, Duration.zero);
  });

  test('start 后进入 running 并落库 + 调原生 start', () async {
    final container = makeContainer();
    final notifier = container.read(focusSessionProvider.notifier);
    await notifier.start();
    await Future.delayed(const Duration(milliseconds: 50));

    final state = container.read(focusSessionProvider);
    expect(state.running, isTrue);
    expect(state.sessionId, isNotNull);
    // 落库
    final repo = FocusSessionRepository(sdb);
    final open = await repo.findOpenSession();
    expect(open, isNotNull);
    // 调原生
    expect(bridgeCalls.any((c) => c.method == 'start'), isTrue);

    await notifier.stop();
  });

  test('stop 后回到 idle 并写 ended_at/duration', () async {
    final container = makeContainer();
    final notifier = container.read(focusSessionProvider.notifier);
    await notifier.start();
    await Future.delayed(const Duration(milliseconds: 50));
    await notifier.stop();

    final state = container.read(focusSessionProvider);
    expect(state.running, isFalse);
    expect(state.sessionId, isNull);
    // DB 会话已结束
    final repo = FocusSessionRepository(sdb);
    expect(await repo.findOpenSession(), isNull);
    // 调原生 stop
    expect(bridgeCalls.any((c) => c.method == 'stop'), isTrue);
  });

  test('running 态再次 start 被拦截', () async {
    final container = makeContainer();
    final notifier = container.read(focusSessionProvider.notifier);
    await notifier.start();
    final firstId = container.read(focusSessionProvider).sessionId;
    await notifier.start(); // 应被拦截
    expect(container.read(focusSessionProvider).sessionId, firstId);
    await notifier.stop();
  });

  test('非 running 态 stop 无副作用', () async {
    final container = makeContainer();
    final notifier = container.read(focusSessionProvider.notifier);
    bridgeCalls.clear();
    await notifier.stop(); // 不应抛、不应调原生
    expect(bridgeCalls, isEmpty);
    expect(container.read(focusSessionProvider).running, isFalse);
  });

  test('recoverOrphan 清理 DB 残留会话（原生未跑）', () async {
    // 预置一个未结束会话
    final repo = FocusSessionRepository(sdb);
    await repo.start(DateTime(2026, 8, 10, 9, 0));

    final container = makeContainer();
    final notifier = container.read(focusSessionProvider.notifier);
    await notifier.recoverOrphan();
    // 应补结束
    expect(await repo.findOpenSession(), isNull);
    expect(container.read(focusSessionProvider).running, isFalse);
  });
}
```

- [ ] **Step 5: 跑测试确认通过**

Run: `cd study_buddy && flutter test test/core/providers/focus_session_provider_test.dart`
Expected: PASS（6 个测试）。若 tick 时序相关断言 flaky，给 `await Future.delayed` 加长。

- [ ] **Step 6: 跑 app 全量回归**

Run: `cd study_buddy && flutter test`
Expected: PASS。

- [ ] **Step 7: 提交**

```bash
git add study_buddy/lib/core/providers/focus_session_provider.dart study_buddy/test/core/providers/focus_session_provider_test.dart
git commit -m "feat(app): FocusSessionNotifier 计时状态机+孤儿会话恢复

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 9: AgentSession 注入 onTopicTouched

**Files:**
- Modify: `study_buddy/lib/core/providers/agent_session_provider.dart`
- Test: 无新增（行为由 Task 5 的 engine 测试覆盖；此 Task 是接线，靠 Task 11 的端到端 widget 测试间接验证）

**Interfaces:**
- Consumes: Task 5 的 `StudyScenario.onTopicTouched`、Task 8 的 `focusSessionProvider`（读当前 sessionId）、Task 3 的 `FocusSessionRepository.linkTopic`
- Produces: `AgentSession.run()` 构造 `StudyScenario` 时注入 `onTopicTouched`：读 `ref.read(focusSessionProvider).sessionId`，非 null 时调 `FocusSessionRepository.linkTopic(sessionId, topicId)`。

- [ ] **Step 1: 修改 agent_session_provider**

修改 `study_buddy/lib/core/providers/agent_session_provider.dart`。在文件顶部加 import：

```dart
import 'focus_session_provider.dart';
```

在 `run()` 方法内构造 `StudyScenario` 处，加 `onTopicTouched` 参数（参照现有构造，替换 `final scenario = StudyScenario(...)` 那段）：

```dart
    final scenario = StudyScenario(
      categories: categories,
      topics: topics,
      edges: edgesRepo,
      memories: memories,
      onTopicTouched: (topicId) async {
        // 仅专注会话进行中才关联；非专注期 no-op
        final sessionId = _ref.read(focusSessionProvider).sessionId;
        if (sessionId == null) return;
        final focusRepo = FocusSessionRepository(db);
        await focusRepo.linkTopic(sessionId, topicId);
      },
    );
```

- [ ] **Step 2: 验证编译**

Run: `cd study_buddy && flutter analyze lib/core/providers/agent_session_provider.dart`
Expected: 无错误。

- [ ] **Step 3: 跑 app 全量回归（确认现有 chat_session_provider_test 不受影响）**

Run: `cd study_buddy && flutter test`
Expected: PASS。注：现有 chat 测试用 fake AgentSession override，不走真实 `run()`，故注入不影响。

- [ ] **Step 4: 提交**

```bash
git add study_buddy/lib/core/providers/agent_session_provider.dart
git commit -m "feat(app): AgentSession 注入 onTopicTouched 关联专注会话

专注会话进行中 AI save/update_topic 时自动关联知识点到当前会话。

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 10: Android 原生 FocusTimerService + FocusTimerPlugin

**Files:**
- Create: `study_buddy/android/app/src/main/kotlin/io/github/yunkst/studybuddy/FocusTimerService.kt`
- Create: `study_buddy/android/app/src/main/kotlin/io/github/yunkst/studybuddy/FocusTimerPlugin.kt`
- Modify: `study_buddy/android/app/src/main/kotlin/io/github/yunkst/studybuddy/MainActivity.kt`
- Modify: `study_buddy/android/app/src/main/AndroidManifest.xml`
- Test: 无自动化测试（前台服务依赖 Android 运行时，靠手测验证；见 Step 6 手测清单）

**Interfaces:**
- Consumes: Task 7 定义的 MethodChannel `study_buddy/focus` 协议（`start(sessionId)` / `stop()` / `isRunning()` / 反向 `onStopped`）
- Produces: 原生前台服务 `FocusTimerService`（通知 id 固定 2001，每秒刷新正文显示 `已专注 HH:MM:SS`，通知 Action「停止」→ 反向调 `onStopped`）；`FocusTimerPlugin` 注册 channel。

**关键参考**：参照现有 `ScreenshotPlugin.kt`（channel 注册模式）与 `OverlayService.kt`（前台服务 + `specialUse` 类型 + 通知渠道模式）。先 Read `OverlayService.kt` 确认通知渠道与 startForeground 写法。

- [ ] **Step 1: 先 Read 参考实现**

Read `study_buddy/android/app/src/main/kotlin/io/github/yunkst/studybuddy/OverlayService.kt` 全文，重点看：
- 通知渠道创建（`NotificationManager.createNotificationChannel`）
- `startForeground` 调用与 `foregroundServiceType`
- 通知 Action 与 PendingIntent 模式

- [ ] **Step 2: 创建 FocusTimerService**

创建 `study_buddy/android/app/src/main/kotlin/io/github/yunkst/studybuddy/FocusTimerService.kt`：

```kotlin
package io.github.yunkst.studybuddy

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import androidx.core.app.NotificationCompat

/**
 * 专注计时前台服务。
 *
 * - startForeground 常驻通知（id=2001）
 * - 每秒刷新通知正文显示已专注时长
 * - 通知「停止」Action → 通过 MethodChannel 反向调用 Flutter 的 onStopped
 *
 * 计时主源在 Flutter，本服务只负责通知展示与转发停止意图。
 */
class FocusTimerService : Service() {
    companion object {
        const val CHANNEL_ID = "focus_timer"
        const val NOTIFICATION_ID = 2001
        const val ACTION_STOP = "io.github.yunkst.studybuddy.ACTION_FOCUS_STOP"
        private var startTimeMs: Long = 0L
        private val handler = Handler(Looper.getMainLooper())

        fun isRunning(context: Context): Boolean {
            val mgr = context.getSystemService(Context.ACTIVITY_SERVICE) as android.app.ActivityManager
            return mgr.getRunningServices(Int.MAX_VALUE)
                ?.any { it.service.className == FocusTimerService::class.java.name } == true
        }
    }

    private val tickRunnable = object : Runnable {
        override fun run() {
            updateNotification()
            handler.postDelayed(this, 1000L)
        }
    }

    override fun onCreate() {
        super.onCreate()
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            notifyFlutterStopped()
            stopSelf()
            return START_NOT_STICKY
        }
        startTimeMs = System.currentTimeMillis()
        startForeground(NOTIFICATION_ID, buildNotification(elapsedMs = 0L))
        handler.post(tickRunnable)
        return START_NOT_STICKY
    }

    private fun updateNotification() {
        val elapsed = System.currentTimeMillis() - startTimeMs
        val mgr = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        mgr.notify(NOTIFICATION_ID, buildNotification(elapsed))
    }

    private fun buildNotification(elapsedMs: Long): Notification {
        val h = (elapsedMs / 3600000).toInt()
        val m = ((elapsedMs % 3600000) / 60000).toInt()
        val s = ((elapsedMs % 60000) / 1000).toInt()
        val text = "已专注 %02d:%02d:%02d".format(h, m, s)

        val stopIntent = Intent(this, FocusTimerService::class.java).apply {
            action = ACTION_STOP
        }
        val stopPi = PendingIntent.getService(
            this, 0, stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("正在专注学习")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_menu_recent_history)
            .setOngoing(true)
            .addAction(android.R.drawable.ic_media_pause, "停止", stopPi)
            .build()
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val mgr = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (mgr.getNotificationChannel(CHANNEL_ID) == null) {
                val ch = NotificationChannel(
                    CHANNEL_ID, "专注计时", NotificationManager.IMPORTANCE_LOW
                ).apply { description = "专注学习计时通知" }
                mgr.createNotificationChannel(ch)
            }
        }
    }

    private fun notifyFlutterStopped() {
        // 反向调用 Flutter onStopped
        val engine = (applicationContext as? study_buddy.StudyBuddyApp)?.flutterEngine
        engine?.let {
            io.flutter.plugin.common.MethodChannel(
                it.dartExecutor.binaryMessenger, "study_buddy/focus"
            ).invokeMethod("onStopped", null)
        }
    }

    override fun onDestroy() {
        handler.removeCallbacks(tickRunnable)
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
```

注：`notifyFlutterStopped` 中获取 `flutterEngine` 的方式依赖 app 是否在 Application/MainActivity 暴露 engine 引用。若 `StudyBuddyApp` 未持有，则改为通过 `FocusTimerPlugin` 静态持有的 binaryMessenger 引用（见 Step 3，plugin 在 onAttached 时缓存 messenger）。**实现时优先用 plugin 静态引用方案**：在 `FocusTimerPlugin` 中 `companion object { var messenger: BinaryMessenger? = null }`，service 通过它反向调用。

- [ ] **Step 3: 创建 FocusTimerPlugin**

创建 `study_buddy/android/app/src/main/kotlin/io/github/yunkst/studybuddy/FocusTimerPlugin.kt`：

```kotlin
package io.github.yunkst.studybuddy

import android.content.Intent
import android.os.Build
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 专注计时 MethodChannel("study_buddy/focus") 桥接。
 *
 * - start(sessionId) → 启动 FocusTimerService 前台服务
 * - stop → 停止服务
 * - isRunning → 查服务是否在跑
 * - onStopped（反向）→ service 通过本 plugin 缓存的 messenger 调 Flutter
 */
class FocusTimerPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    companion object {
        var messenger: io.flutter.plugin.common.BinaryMessenger? = null
    }

    private var channel: MethodChannel? = null
    private var appContext: android.content.Context? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        messenger = binding.binaryMessenger
        channel = MethodChannel(binding.binaryMessenger, "study_buddy/focus").also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        messenger = null
        appContext = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> {
                val ctx = appContext ?: run { result.success(null); return }
                val intent = Intent(ctx, FocusTimerService::class.java)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    ctx.startForegroundService(intent)
                } else {
                    ctx.startService(intent)
                }
                result.success(null)
            }
            "stop" -> {
                appContext?.let {
                    it.stopService(Intent(it, FocusTimerService::class.java))
                }
                result.success(null)
            }
            "isRunning" -> {
                val running = appContext?.let { FocusTimerService.isRunning(it) } ?: false
                result.success(running)
            }
            else -> result.notImplemented()
        }
    }
}
```

- [ ] **Step 4: 修改 FocusTimerService 用 plugin messenger**

回到 `FocusTimerService.notifyFlutterStopped()`，用 plugin 缓存的 messenger 替换 Step 2 的临时实现：

```kotlin
    private fun notifyFlutterStopped() {
        val m = FocusTimerPlugin.messenger ?: return
        io.flutter.plugin.common.MethodChannel(m, "study_buddy/focus")
            .invokeMethod("onStopped", null)
    }
```

- [ ] **Step 5: 注册 plugin + 声明 service**

修改 `study_buddy/android/app/src/main/kotlin/io/github/yunkst/studybuddy/MainActivity.kt`，在 `configureFlutterEngine` 内 `flutterEngine.plugins.add(ScreenshotPlugin())` 之后加：

```kotlin
        flutterEngine.plugins.add(FocusTimerPlugin())
```

修改 `study_buddy/android/app/src/main/AndroidManifest.xml`，在 `<manifest>` 的权限区加（Android 13+ 通知权限）：

```xml
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
```

在 `<application>` 内（`ScreenCaptureService` service 声明之后）加：

```xml
        <service
            android:name=".FocusTimerService"
            android:exported="false"
            android:foregroundServiceType="specialUse">
            <property
                android:name="android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE"
                android:value="Focus study timer notification" />
        </service>
```

- [ ] **Step 6: 手测清单（无自动化测试，靠人工验证）**

构建并安装到 Android 设备/模拟器后验证：
1. app 内点「开始专注」→ 通知栏出现「正在专注学习 已专注 00:00:01」并每秒递增。
2. 锁屏后通知仍可见，时间继续递增。
3. 点通知「停止」Action → 通知消失，app 内计时停止、状态回到 idle。
4. app 内点「结束专注」→ 通知消失。
5. 专注中按 Home 切后台 → 通知仍在、时间递增；回前台 app 内计时同步。

Run（构建）:
```bash
cd study_buddy && flutter build apk --debug 2>&1 | tail -5
```
Expected: 构建成功无 Kotlin 编译错误。

- [ ] **Step 7: 跑 app Dart 侧全量回归（确认无编译破坏）**

Run: `cd study_buddy && flutter test`
Expected: PASS。

- [ ] **Step 8: 提交**

```bash
git add study_buddy/android/app/src/main/kotlin/io/github/yunkst/studybuddy/FocusTimerService.kt \
        study_buddy/android/app/src/main/kotlin/io/github/yunkst/studybuddy/FocusTimerPlugin.kt \
        study_buddy/android/app/src/main/kotlin/io/github/yunkst/studybuddy/MainActivity.kt \
        study_buddy/android/app/src/main/AndroidManifest.xml
git commit -m "feat(android): FocusTimerService 前台服务+通知栏实时计时+停止按钮

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 11: 专注页 UI

**Files:**
- Create: `study_buddy/lib/features/focus/focus_page.dart`
- Modify: `study_buddy/lib/router.dart`（加 `/focus` 路由）
- Modify: `study_buddy/lib/features/home/home_page.dart`（加入口按钮）
- Test: `study_buddy/test/features/focus/focus_page_test.dart`

**Interfaces:**
- Consumes: Task 8 的 `focusSessionProvider`
- Produces: `FocusPage`（ConsumerStatefulWidget）；路由 `/focus`。UI：大号计时显示（HH:MM:SS，从 `state.elapsed` 格式化）+ 开始/结束按钮（根据 `state.running` 切换）+ 已专注中提示文案。

- [ ] **Step 1: 写失败测试**

创建 `study_buddy/test/features/focus/focus_page_test.dart`：

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:study_buddy/core/providers/focus_session_provider.dart';
import 'package:study_buddy/features/focus/focus_page.dart';

void main() {
  testWidgets('idle 态显示开始按钮', (tester) async {
    final container = ProviderContainer(overrides: [
      focusSessionProvider.overrideWith((ref) => _FakeNotifier(ref)),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: FocusPage()),
    ));

    expect(find.text('开始专注'), findsOneWidget);
    expect(find.text('结束专注'), findsNothing);
  });

  testWidgets('running 态显示结束按钮与计时', (tester) async {
    final container = ProviderContainer(overrides: [
      focusSessionProvider.overrideWith((ref) =>
          _FakeNotifier(ref, state: const FocusSessionState(
            sessionId: 1, running: true, elapsed: Duration(minutes: 5, seconds: 3),
          ))),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: FocusPage()),
    ));

    expect(find.text('结束专注'), findsOneWidget);
    expect(find.text('开始专注'), findsNothing);
    expect(find.text('00:05:03'), findsOneWidget);
  });

  testWidgets('点开始按钮调用 start', (tester) async {
    final container = ProviderContainer(overrides: [
      focusSessionProvider.overrideWith((ref) => _FakeNotifier(ref)),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: FocusPage()),
    ));

    await tester.tap(find.text('开始专注'));
    await tester.pump();
    final notifier = container.read(focusSessionProvider.notifier) as _FakeNotifier;
    expect(notifier.startCalled, isTrue);
  });
}

class _FakeNotifier extends FocusSessionNotifier {
  _FakeNotifier(super.ref, {FocusSessionState? state})
      : super() {
    if (state != null) this.state = state;
  }
  bool startCalled = false;
  @override
  Future<void> start() async { startCalled = true; }
  @override
  Future<void> stop() async {}
}
```

注：`_FakeNotifier` 继承 `FocusSessionNotifier` 但 override `start`/`stop` 避免触发真实 DB/channel。若 `FocusSessionNotifier` 构造要求 `Ref` 导致 fake 无法编译，改为 `StateNotifierProvider` override 返回 fake 实例（Riverpod 3 的 `overrideWith((ref) => ...)` 模式，见 `chat_session_provider_test.dart`）。

- [ ] **Step 2: 跑测试确认失败**

Run: `cd study_buddy && flutter test test/features/focus/focus_page_test.dart`
Expected: FAIL —— `FocusPage` 未定义。

- [ ] **Step 3: 实现 FocusPage**

创建 `study_buddy/lib/features/focus/focus_page.dart`：

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/focus_session_provider.dart';

class FocusPage extends ConsumerWidget {
  const FocusPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(focusSessionProvider);
    final notifier = ref.read(focusSessionProvider.notifier);

    final h = state.elapsed.inHours.toString().padLeft(2, '0');
    final m = (state.elapsed.inMinutes % 60).toString().padLeft(2, '0');
    final s = (state.elapsed.inSeconds % 60).toString().padLeft(2, '0');

    return Scaffold(
      appBar: AppBar(title: const Text('专注时钟')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '$h:$m:$s',
              style: const TextStyle(
                fontSize: 64,
                fontWeight: FontWeight.w300,
                color: Colors.deepPurple,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              state.running ? '专注中…' : '准备好就开始吧',
              style: TextStyle(color: Colors.grey.shade600),
            ),
            const SizedBox(height: 32),
            if (state.running)
              FilledButton.icon(
                icon: const Icon(Icons.stop),
                label: const Text('结束专注'),
                onPressed: () => notifier.stop(),
              )
            else
              FilledButton.icon(
                icon: const Icon(Icons.play_arrow),
                label: const Text('开始专注'),
                onPressed: () => notifier.start(),
              ),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: 加路由 + 入口**

修改 `study_buddy/lib/router.dart`，import 与路由：

```dart
import '../features/focus/focus_page.dart';
```
在 `routes` 列表加：
```dart
      GoRoute(
        path: '/focus',
        builder: (context, state) => const FocusPage(),
      ),
```

修改 `study_buddy/lib/features/home/home_page.dart`，在 body 的 Column children 中（`if (Platform.isAndroid)` 块之前）加入口：

```dart
                const SizedBox(height: 12),
                FilledButton.icon(
                  icon: const Icon(Icons.timer),
                  label: const Text('开始专注'),
                  onPressed: () => context.go('/focus'),
                ),
                const SizedBox(height: 8),
                TextButton.icon(
                  icon: const Icon(Icons.assignment),
                  label: const Text('学习日报'),
                  onPressed: () => context.go('/daily-report'),
                ),
```

需在 home_page.dart 顶部确认 `go_router` 的 `contextGo` 扩展已 import（现有文件已 import `go_router`）。

- [ ] **Step 5: 跑测试确认通过**

Run: `cd study_buddy && flutter test test/features/focus/focus_page_test.dart`
Expected: PASS（3 个测试）。若 `_FakeNotifier` 因 `FocusSessionNotifier` 构造或 `mounted` 检查编译失败，调整 fake：构造时不调 super 内部逻辑（`FocusSessionNotifier` 构造只赋值 `_ref` 与 `super(idle)`，应可继承）。

- [ ] **Step 6: 跑 app 全量回归**

Run: `cd study_buddy && flutter test`
Expected: PASS。注：`widget_test.dart` 现有首页渲染测试可能因加了按钮而变化，若失败需更新其断言——先 Read `widget_test.dart` 确认。

- [ ] **Step 7: 提交**

```bash
git add study_buddy/lib/features/focus/focus_page.dart \
        study_buddy/lib/router.dart \
        study_buddy/lib/features/home/home_page.dart \
        study_buddy/test/features/focus/focus_page_test.dart
git commit -m "feat(app): 专注页 UI + 首页入口

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 12: 日报页 UI

**Files:**
- Create: `study_buddy/lib/features/focus/daily_report_page.dart`
- Modify: `study_buddy/lib/router.dart`（加 `/daily-report` 路由）
- Test: `study_buddy/test/features/focus/daily_report_page_test.dart`

**Interfaces:**
- Consumes: Task 4 的 `buildDailyReport`、`databaseProvider`、`TopicRepository`、`FocusSessionRepository`、现有 `CategoryRepository.pathOf`（展示知识点路径）
- Produces: `DailyReportPage`（ConsumerStatefulWidget）；路由 `/daily-report`。UI：
  - 顶部日期选择（默认今天，可左右切一天）
  - 总用时卡片（格式化为 `X小时Y分`）
  - 会话列表（每条：起止时间范围 `09:00–09:30` + 时长）
  - 当天知识点列表（title + 路径）

- [ ] **Step 1: 写失败测试**

创建 `study_buddy/test/features/focus/daily_report_page_test.dart`：

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:study_buddy/core/providers/database_provider.dart';
import 'package:study_buddy/features/focus/daily_report_page.dart';
import 'package:study_engine/study_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  late StudyDatabase sdb;

  setUp(() async {
    sdb = await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
  });
  tearDown(() async => await sdb.close());

  Future<void> seedSession({
    required int startHour, required int endHour, required List<String> topicTitles,
  }) async {
    final focusRepo = FocusSessionRepository(sdb);
    final topicRepo = TopicRepository(sdb);
    final cats = CategoryRepository(sdb);
    final catId = await cats.ensurePath(['数学']);
    final now = DateTime(2026, 8, 10);
    final id = await focusRepo.start(DateTime(2026, 8, 10, startHour));
    final dur = (endHour - startHour) * 3600000;
    await focusRepo.end(id, DateTime(2026, 8, 10, endHour), dur);
    for (final title in topicTitles) {
      final tid = await topicRepo.insert(Topic(
        categoryId: catId, question: 'q', title: title, summary: 's',
        createdAt: now, updatedAt: now,
      ));
      await focusRepo.linkTopic(id, tid);
    }
  }

  testWidgets('空日报显示空态文案', (tester) async {
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWith((ref) async {
        ref.onDispose(() => sdb.close());
        return sdb;
      }),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: DailyReportPage()),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('没有专注记录'), findsOneWidget);
  });

  testWidgets('有数据时显示总用时/会话时间范围/知识点', (tester) async {
    await seedSession(startHour: 9, endHour: 10, topicTitles: ['极限', '导数']);
    await seedSession(startHour: 14, endHour: 15, topicTitles: ['连续']);

    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWith((ref) async {
        ref.onDispose(() => sdb.close());
        return sdb;
      }),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: DailyReportPage()),
    ));
    await tester.pumpAndSettle();

    // 总用时 2 小时
    expect(find.textContaining('2小时'), findsOneWidget);
    // 会话时间范围
    expect(find.textContaining('09:00–10:00'), findsOneWidget);
    expect(find.textContaining('14:00–15:00'), findsOneWidget);
    // 知识点
    expect(find.text('极限'), findsOneWidget);
    expect(find.text('导数'), findsOneWidget);
    expect(find.text('连续'), findsOneWidget);
  });
}
```

注：日报页默认展示「今天」。测试种子数据日期为 2026-08-10，若「今天」不是该日期，测试需让页面支持初始日期参数或注入。**实现时**让 `DailyReportPage` 接受可选 `initialDate`（默认 `DateTime.now()`），测试用 `DailyReportPage(initialDate: DateTime(2026,8,10))`。更新测试的 `DailyReportPage()` 为 `DailyReportPage(initialDate: DateTime(2026, 8, 10))`。

- [ ] **Step 2: 跑测试确认失败**

Run: `cd study_buddy && flutter test test/features/focus/daily_report_page_test.dart`
Expected: FAIL —— `DailyReportPage` 未定义。

- [ ] **Step 3: 实现 DailyReportPage**

创建 `study_buddy/lib/features/focus/daily_report_page.dart`：

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:study_engine/study_engine.dart';

import '../../core/providers/database_provider.dart';

class DailyReportPage extends ConsumerStatefulWidget {
  final DateTime initialDate;
  const DailyReportPage({super.key, DateTime? initialDate})
      : initialDate = initialDate ?? _today;

  static DateTime get _today {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  @override
  ConsumerState<DailyReportPage> createState() => _DailyReportPageState();
}

class _DailyReportPageState extends ConsumerState<DailyReportPage> {
  late DateTime _date = widget.initialDate;
  Future<DailyReport>? _reportFuture;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _reportFuture = _build();
  }

  Future<DailyReport> _build() async {
    final db = await ref.read(databaseProvider.future);
    return buildDailyReport(
      focusRepo: FocusSessionRepository(db),
      topicRepo: TopicRepository(db),
      date: _date,
    );
  }

  void _changeDay(int delta) {
    setState(() {
      _date = _date.add(Duration(days: delta));
      _load();
    });
  }

  String _fmtDuration(int ms) {
    final h = ms ~/ 3600000;
    final m = (ms % 3600000) ~/ 60000;
    if (h == 0) return '$m分钟';
    if (m == 0) return '$h小时';
    return '$h小时$m分';
  }

  String _fmtTime(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${_date.month}月${_date.day}日 学习日报'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: FutureBuilder<DailyReport>(
        future: _reportFuture,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final report = snap.data!;
          if (report.sessions.isEmpty) {
            return const Center(child: Text('这天没有专注记录'));
          }
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                child: ListTile(
                  leading: const Icon(Icons.timer, color: Colors.deepPurple),
                  title: const Text('总专注用时'),
                  subtitle: Text(_fmtDuration(report.totalDurationMs),
                      style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                ),
              ),
              const SizedBox(height: 8),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Text('专注会话', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
              ...report.sessions.map((s) {
                final start = s.session.startedAt;
                final end = s.session.endedAt;
                final range = end != null
                    ? '${_fmtTime(start)}–${_fmtTime(end)}'
                    : '${_fmtTime(start)}–进行中';
                return Card(
                  child: ListTile(
                    leading: const Icon(Icons.schedule),
                    title: Text(range),
                    subtitle: Text(_fmtDuration(s.session.durationMs ?? 0)),
                  ),
                );
              }),
              const SizedBox(height: 8),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Text('今天学过的知识点', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
              ...report.uniqueTopics.map((t) => Card(
                    child: ListTile(
                      leading: const Icon(Icons.lightbulb_outline, color: Colors.amber),
                      title: Text(t.title),
                    ),
                  )),
            ],
          );
        },
      ),
      bottomNavigationBar: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            TextButton.icon(
              icon: const Icon(Icons.chevron_left),
              label: const Text('前一天'),
              onPressed: () => _changeDay(-1),
            ),
            TextButton.icon(
              icon: const Icon(Icons.chevron_right),
              label: const Text('后一天'),
              onPressed: () => _changeDay(1),
            ),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: 加路由**

修改 `study_buddy/lib/router.dart`，import 与路由：

```dart
import '../features/focus/daily_report_page.dart';
```
在 `routes` 列表加：
```dart
      GoRoute(
        path: '/daily-report',
        builder: (context, state) => const DailyReportPage(),
      ),
```

- [ ] **Step 5: 跑测试确认通过**

Run: `cd study_buddy && flutter test test/features/focus/daily_report_page_test.dart`
Expected: PASS（2 个测试）。测试中 `DailyReportPage()` 需改为 `DailyReportPage(initialDate: DateTime(2026, 8, 10))`（Step 1 已注）。

- [ ] **Step 6: 跑 app 全量回归**

Run: `cd study_buddy && flutter test`
Expected: PASS。

- [ ] **Step 7: 提交**

```bash
git add study_buddy/lib/features/focus/daily_report_page.dart \
        study_buddy/lib/router.dart \
        study_buddy/test/features/focus/daily_report_page_test.dart
git commit -m "feat(app): 学习日报页 UI——总用时/会话时间范围/知识点列表

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 13: 孤儿会话恢复接线 + 启动恢复

**Files:**
- Modify: `study_buddy/lib/app.dart`（app 启动后调 `recoverOrphan`）
- Test: `study_buddy/test/features/focus/focus_page_test.dart`（追加）或 `study_buddy/test/widget_test.dart`

**Interfaces:**
- Consumes: Task 8 的 `FocusSessionNotifier.recoverOrphan`
- Produces: app 首帧后调用 `ref.read(focusSessionProvider.notifier).recoverOrphan()`，与现有 `bootstrapOverlay` 并列。

- [ ] **Step 1: 修改 app.dart**

在 `study_buddy/lib/app.dart` 的 `_StudyBuddyAppState.initState` 的 `addPostFrameCallback` 内，`bootstrapOverlay` 之后加：

```dart
      // 恢复或清理上次未结束的专注会话
      ref.read(focusSessionProvider.notifier).recoverOrphan();
```

顶部加 import：
```dart
import 'core/providers/focus_session_provider.dart';
```

- [ ] **Step 2: 验证编译 + 回归**

Run: `cd study_buddy && flutter analyze lib/app.dart && flutter test`
Expected: 无错误，测试全绿。

- [ ] **Step 3: 提交**

```bash
git add study_buddy/lib/app.dart
git commit -m "feat(app): 启动时恢复或清理孤儿专注会话

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 14: 最终回归与收尾

**Files:**
- 无新增，全量验证

- [ ] **Step 1: engine 全量回归**

Run: `cd packages/study_engine && flutter test`
Expected: PASS（原 34 + 新增 ≈ 22 = ~56）。

- [ ] **Step 2: app 全量回归**

Run: `cd study_buddy && flutter test`
Expected: PASS（原 44 + 新增 ≈ 15 = ~59）。

- [ ] **Step 3: 静态分析**

Run: `cd study_buddy && flutter analyze` 与 `cd packages/study_engine && flutter analyze`
Expected: 无 error（warning 可接受但尽量清零）。

- [ ] **Step 4: Android 构建验证**

Run: `cd study_buddy && flutter build apk --debug 2>&1 | tail -5`
Expected: 构建成功。

- [ ] **Step 5: 手测端到端清单**

安装到设备，完整走查：
1. 首页点「开始专注」→ 专注页计时启动 + 通知栏出现。
2. 专注中切到其他 app，悬浮球截图 → AI 抽屉分析保存知识点。
3. 通知栏「停止」或 app 内「结束专注」→ 会话落库。
4. 首页点「学习日报」→ 看到当天总用时、会话时间范围、刚学的知识点。
5. 杀进程重启 app → 若有未结束会话，恢复 running 或清理。
6. 日报页切前一天/后一天，空态正确。

- [ ] **Step 6: 更新 memory（可选）**

在 `C:\Users\KFEB4\.claude\projects\D--my-space-study\memory\` 新建 `focus-clock-done.md` 记录功能完成状态，并在 `MEMORY.md` 加索引行。内容：专注时钟+学习日报完成（日期、commit、技术要点、待办如 iOS 支持）。

- [ ] **Step 7: 最终提交（若有 memory 改动）**

```bash
git add docs/  # 若有 plan/spec 已提交则跳过
git commit -m "chore: 专注时钟功能收尾" --allow-empty
```

---

## Self-Review

**1. Spec 覆盖：**
- §1.1 MVP 目标 1（开始/通知栏/停止）→ Task 8 + 10 + 11 ✅
- §1.1 目标 2（AI 关联知识点）→ Task 5 + 9 ✅
- §1.1 目标 3（结束落库，app 内或通知栏）→ Task 8（stop 统一入口）+ Task 10（通知栏停止回传）✅
- §1.1 目标 4（日报页：总用时/时间范围/知识点/历史日期）→ Task 12 ✅
- §1.2 约束（不暂停/实时计时/不拆时长/截图不入报/向后兼容/跨进程一致）→ 状态机无 pause、通知栏每秒刷新、日报无 per-topic 时长、onTopicTouched 仅 sessionId 非空时关联、_v3 仅加表、Flutter 主源 ✅
- §5 孤儿会话清理 → Task 8 recoverOrphan + Task 13 接线 ✅
- §5 Android 13+ 通知权限 → Task 10 声明 POST_NOTIFICATIONS（运行时申请在 Task 10 Step 5 手测，代码层声明已覆盖；运行时请求可在 FocusPage.start 前补，作为已知增强项）⚠️ 注：计划中未显式加运行时请求代码，因 `flutter_local_notifications` 未引入、手测可验证声明是否足够。若手测发现 13+ 上通知不出现，需补 `permission_handler` 或原生请求——列为风险，不阻塞 MVP。

**2. Placeholder scan：** 无 TBD/TODO。Task 10 Step 6 手测清单为验证步骤非占位。Task 7/8 测试有「若失败则调整」的备注，是防御性指引，非占位。

**3. Type consistency：**
- `FocusSession`/`FocusSessionTopic` 字段名在 Task 1/3/4 一致 ✅
- `FocusSessionRepository` 方法名 `start/end/linkTopic/findByDate/topicIdsOf/findOpenSession` 在 Task 3 定义、Task 4/8/9/12 消费一致 ✅
- `buildDailyReport` 签名在 Task 4 定义、Task 12 消费一致 ✅
- `onTopicTouched` 签名 `Future<void> Function(int topicId)?` 在 Task 5 定义、Task 9 消费一致 ✅
- `FocusTimerBridge` 方法 `start(int)/stop()/isRunning()/setOnStopped` 在 Task 7 定义、Task 8 消费一致 ✅
- `FocusSessionState` 字段 `sessionId/startedAt/elapsed/running` 在 Task 8 定义、Task 11 消费一致 ✅

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-08-10-focus-clock-daily-report.md`. Two execution options:

1. **Subagent-Driven (recommended)** — 每个 Task 派一个 fresh subagent，任务间 review，快速迭代。
2. **Inline Execution** — 在当前 session 用 executing-plans 批量执行，设检查点 review。

Which approach?
