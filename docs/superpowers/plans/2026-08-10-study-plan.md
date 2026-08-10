# 学习计划功能 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 study_buddy APP 新增学习计划功能——AI 把考试目标拆成里程碑节点，手动录分测评，画进步曲线，并支持随时对话调整。

**Architecture:** 引擎层（study_engine，纯 Dart）新增 Plan/Milestone/Assessment 三模型 + v3 迁移 + PlanRepository + PlanScenario（7 工具，沿用 AgentLoop）。APP 层新增 PlanSession（注入当前 plan 概要 + 当前日期到 system prompt）+ 计划页面/弹窗。零新依赖（CustomPainter 手绘曲线，APP 内提醒）。

**Tech Stack:** Dart 3.9 / Flutter / Riverpod 3 / go_router / sqflite_common_ffi / OpenAI 兼容 SSE function calling。

## Global Constraints

- 数据库版本 `kCurrentDbVersion` 由 2 升至 3，**只增不改**既有表。
- SQLite FK 已在 `database.dart` 的 `onConfigure` 启用（`PRAGMA foreign_keys = ON`），CASCADE 删除生效。
- 引擎层（`packages/study_engine`）零 Flutter 依赖；模型 `fromMap`/`toMap` 与既有 `models.dart` 风格一致（毫秒时间戳）。
- 测试用 `sqflite_common_ffi` + `inMemoryDatabasePath`，仿 `repos_test.dart` / `study_scenario_integration_test.dart` 模式。
- engine 测试运行命令：`cd packages/study_engine && dart test`。
- APP 层 LLM 配置：计划场景 `vision: false`（截图场景才 `vision: true`），避免强制视觉模型。
- 提醒阈值固定 14 天；提醒纯 APP 内检查，不引 local_notifications。
- 曲线用 Flutter 内置 `CustomPainter`，不引 fl_chart。
- 删除整个计划是高危操作，不在 AI 工具里——用户 UI 手动执行（走 CASCADE）。
- 响应中文（用户全局偏好）。

## File Structure

**study_engine（引擎层，纯 Dart）：**
- Create: `packages/study_engine/lib/src/models/plan_models.dart` — Plan / Milestone / Assessment 三模型
- Modify: `packages/study_engine/lib/src/models/models.dart` — 末尾 export plan_models.dart
- Modify: `packages/study_engine/lib/src/db/database_migrations.dart` — kCurrentDbVersion 2→3，加 `_v3`
- Create: `packages/study_engine/lib/src/repos/plan_repository.dart` — Plan/Milestone/Assessment CRUD + 聚合查询
- Create: `packages/study_engine/lib/src/agent/plan_tools.dart` — 7 工具 schema
- Create: `packages/study_engine/lib/src/agent/scenarios/plan_scenario.dart` — PlanScenario
- Modify: `packages/study_engine/lib/study_engine.dart` — barrel 追加导出
- Create: `packages/study_engine/test/plan_models_test.dart` — 模型往返测试
- Modify: `packages/study_engine/test/db_test.dart` — 加 v3 三表存在性 + 升级测试
- Create: `packages/study_engine/test/plan_repo_test.dart` — repo CRUD + 聚合 + CASCADE 测试
- Create: `packages/study_engine/test/plan_scenario_integration_test.dart` — 7 工具集成测试

**study_buddy（APP 层）：**
- Create: `study_buddy/lib/core/providers/plan_provider.dart` — planRepositoryProvider / planListProvider / planDetailProvider / planSessionProvider
- Create: `study_buddy/lib/features/plan/plan_detail_page.dart` — 详情页（提醒横幅 + 曲线 + 时间线）
- Create: `study_buddy/lib/features/plan/progress_chart.dart` — CustomPainter 曲线 widget
- Create: `study_buddy/lib/features/plan/assessment_entry_sheet.dart` — 录分弹窗
- Create: `study_buddy/lib/features/plan/plan_chat_sheet.dart` — AI 对话弹窗
- Modify: `study_buddy/lib/features/home/home_page.dart` — 改计划列表入口
- Modify: `study_buddy/lib/router.dart` — 加 `/plan/:id` 路由

---

## Task 1: Plan / Milestone / Assessment 三模型

**Files:**
- Create: `packages/study_engine/lib/src/models/plan_models.dart`
- Modify: `packages/study_engine/lib/src/models/models.dart`
- Create: `packages/study_engine/test/plan_models_test.dart`

**Interfaces:**
- Produces: `Plan` / `Milestone` / `Assessment` 三个不可变类，各含 `id?` + 业务字段 + `createdAt`（Milestone/Plan 另有 `updatedAt`），`fromMap`/`toMap` 与 `models.dart` 既有风格一致（DateTime ↔ 毫秒 int）。`Milestone.status` 为 String（`'pending'`/`'done'`）。

- [ ] **Step 1: Write the failing test**

Create `packages/study_engine/test/plan_models_test.dart`:

```dart
import 'package:test/test.dart';
import 'package:study_engine/study_engine.dart';

void main() {
  test('Plan toMap/fromMap 往返', () {
    final now = DateTime.utc(2026, 8, 10);
    final p = Plan(
      name: '考研冲刺',
      examDate: DateTime.utc(2026, 12, 21),
      examContent: '政治、英语一、数学一、408',
      target: '总分 380',
      dailyMinutes: 180,
      currentLevel: '估 300 分，数学最弱',
      createdAt: now,
      updatedAt: now,
    );
    final m = p.toMap();
    expect(m['name'], '考研冲刺');
    expect(m['daily_minutes'], 180);
    expect(m['exam_date'], DateTime.utc(2026, 12, 21).millisecondsSinceEpoch);
    final back = Plan.fromMap({'id': 1, ...m});
    expect(back.id, 1);
    expect(back.name, '考研冲刺');
    expect(back.examDate, DateTime.utc(2026, 12, 21));
    expect(back.dailyMinutes, 180);
  });

  test('Milestone toMap/fromMap 往返含 status', () {
    final now = DateTime.utc(2026, 8, 10);
    final ms = Milestone(
      planId: 1,
      title: '数学基础过完',
      description: '高数+线代基础课，能做基础题',
      targetDate: DateTime.utc(2026, 9, 30),
      sortOrder: 2,
      status: 'pending',
      createdAt: now,
      updatedAt: now,
    );
    final m = ms.toMap();
    expect(m['plan_id'], 1);
    expect(m['status'], 'pending');
    expect(m['sort_order'], 2);
    final back = Milestone.fromMap({'id': 5, ...m});
    expect(back.id, 5);
    expect(back.status, 'pending');
    expect(back.targetDate, DateTime.utc(2026, 9, 30));
  });

  test('Assessment toMap/fromMap 往返含可空 score', () {
    final now = DateTime.utc(2026, 8, 20);
    final a = Assessment(
      planId: 1,
      score: 310,
      note: '线代大题崩了',
      assessedAt: now,
      createdAt: now,
    );
    final m = a.toMap();
    expect(m['score'], 310);
    expect(m['note'], '线代大题崩了');
    final back = Assessment.fromMap({'id': 3, ...m});
    expect(back.id, 3);
    expect(back.score, 310);

    // score 为 null
    final a2 = Assessment(planId: 1, score: null, note: '定性：感觉有进步', assessedAt: now, createdAt: now);
    expect(a2.toMap()['score'], isNull);
    final back2 = Assessment.fromMap({'id': 4, ...a2.toMap()});
    expect(back2.score, isNull);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/study_engine && dart test test/plan_models_test.dart`
Expected: FAIL — `Plan` / `Milestone` / `Assessment` 未定义（编译错误）。

- [ ] **Step 3: Write minimal implementation**

Create `packages/study_engine/lib/src/models/plan_models.dart`:

```dart
/// 学习计划三模型。对应 v3 新增表，不依赖 Flutter。
library;

/// 学习计划本体：用户给定的目标元信息。
class Plan {
  final int? id;
  final String name;
  final DateTime examDate;
  final String examContent;
  final String target;
  final int dailyMinutes;
  final String? currentLevel;
  final DateTime createdAt;
  final DateTime updatedAt;
  const Plan({
    this.id,
    required this.name,
    required this.examDate,
    required this.examContent,
    required this.target,
    required this.dailyMinutes,
    this.currentLevel,
    required this.createdAt,
    required this.updatedAt,
  });

  factory Plan.fromMap(Map<String, Object?> m) => Plan(
        id: m['id'] as int?,
        name: m['name'] as String,
        examDate: DateTime.fromMillisecondsSinceEpoch(m['exam_date'] as int),
        examContent: m['exam_content'] as String,
        target: m['target'] as String,
        dailyMinutes: m['daily_minutes'] as int,
        currentLevel: m['current_level'] as String?,
        createdAt: DateTime.fromMillisecondsSinceEpoch(m['created_at'] as int),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(m['updated_at'] as int),
      );
  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'name': name,
        'exam_date': examDate.millisecondsSinceEpoch,
        'exam_content': examContent,
        'target': target,
        'daily_minutes': dailyMinutes,
        if (currentLevel != null) 'current_level': currentLevel,
        'created_at': createdAt.millisecondsSinceEpoch,
        'updated_at': updatedAt.millisecondsSinceEpoch,
      };
}

/// 里程碑节点：AI 拆出的阶段目标，按时间线序列排。
class Milestone {
  final int? id;
  final int planId;
  final String title;
  final String description;
  final DateTime targetDate;
  final int sortOrder;
  final String status; // 'pending' | 'done'
  final DateTime createdAt;
  final DateTime updatedAt;
  const Milestone({
    this.id,
    required this.planId,
    required this.title,
    required this.description,
    required this.targetDate,
    this.sortOrder = 0,
    this.status = 'pending',
    required this.createdAt,
    required this.updatedAt,
  });

  factory Milestone.fromMap(Map<String, Object?> m) => Milestone(
        id: m['id'] as int?,
        planId: m['plan_id'] as int,
        title: m['title'] as String,
        description: m['description'] as String,
        targetDate: DateTime.fromMillisecondsSinceEpoch(m['target_date'] as int),
        sortOrder: (m['sort_order'] as int?) ?? 0,
        status: m['status'] as String,
        createdAt: DateTime.fromMillisecondsSinceEpoch(m['created_at'] as int),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(m['updated_at'] as int),
      );
  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'plan_id': planId,
        'title': title,
        'description': description,
        'target_date': targetDate.millisecondsSinceEpoch,
        'sort_order': sortOrder,
        'status': status,
        'created_at': createdAt.millisecondsSinceEpoch,
        'updated_at': updatedAt.millisecondsSinceEpoch,
      };
}

/// 测评记录：手动录分，承载进步曲线数据点。score 可空（无法量化时只记 note）。
class Assessment {
  final int? id;
  final int planId;
  final int? score;
  final String? note;
  final DateTime assessedAt;
  final DateTime createdAt;
  const Assessment({
    this.id,
    required this.planId,
    required this.score,
    this.note,
    required this.assessedAt,
    required this.createdAt,
  });

  factory Assessment.fromMap(Map<String, Object?> m) => Assessment(
        id: m['id'] as int?,
        planId: m['plan_id'] as int,
        score: m['score'] as int?,
        note: m['note'] as String?,
        assessedAt: DateTime.fromMillisecondsSinceEpoch(m['assessed_at'] as int),
        createdAt: DateTime.fromMillisecondsSinceEpoch(m['created_at'] as int),
      );
  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'plan_id': planId,
        if (score != null) 'score': score,
        if (note != null) 'note': note,
        'assessed_at': assessedAt.millisecondsSinceEpoch,
        'created_at': createdAt.millisecondsSinceEpoch,
      };
}
```

Modify `packages/study_engine/lib/src/models/models.dart` — 在文件末尾追加：

```dart

export 'plan_models.dart';
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd packages/study_engine && dart test test/plan_models_test.dart`
Expected: PASS（3 个测试全过）。

- [ ] **Step 5: Commit**

```bash
git add packages/study_engine/lib/src/models/plan_models.dart packages/study_engine/lib/src/models/models.dart packages/study_engine/test/plan_models_test.dart
git commit -m "feat(models): Plan/Milestone/Assessment 三模型 + 往返测试"
```

---

## Task 2: 数据库迁移 v3（三表）

**Files:**
- Modify: `packages/study_engine/lib/src/db/database_migrations.dart`
- Modify: `packages/study_engine/test/db_test.dart`

**Interfaces:**
- Consumes: Task 1 的三模型（迁移建表供模型落库）。
- Produces: `kCurrentDbVersion = 3`；`_v3(Batch)` 建 `plan` / `milestone` / `assessment` 三表 + 索引，FK CASCADE。`migrateDatabase` switch 加 `case 3`。

- [ ] **Step 1: Write the failing test**

Modify `packages/study_engine/test/db_test.dart` — 在 `main()` 内既有测试后追加两个测试：

```dart
  test('v3 新增 plan/milestone/assessment 三表', () async {
    final factory = databaseFactoryFfi;
    final sdb = await StudyDatabase.open(factory: factory, path: inMemoryDatabasePath);
    final tables = await sdb.db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name",
    );
    final names = tables.map((r) => r['name'] as String).toSet();
    for (final t in ['plan', 'milestone', 'assessment']) {
      expect(names, contains(t), reason: '缺表: $t');
    }
    await sdb.close();
  });

  test('FK CASCADE：删 plan 连带删 milestone 与 assessment', () async {
    final factory = databaseFactoryFfi;
    final sdb = await StudyDatabase.open(factory: factory, path: inMemoryDatabasePath);
    final now = DateTime.now();
    final pid = await sdb.db.insert('plan', {
      'name': '考研', 'exam_date': now.millisecondsSinceEpoch, 'exam_content': 'c',
      'target': 't', 'daily_minutes': 180,
      'created_at': now.millisecondsSinceEpoch, 'updated_at': now.millisecondsSinceEpoch,
    });
    await sdb.db.insert('milestone', {
      'plan_id': pid, 'title': 'm1', 'description': 'd', 'target_date': now.millisecondsSinceEpoch,
      'sort_order': 0, 'status': 'pending',
      'created_at': now.millisecondsSinceEpoch, 'updated_at': now.millisecondsSinceEpoch,
    });
    await sdb.db.insert('assessment', {
      'plan_id': pid, 'score': 300, 'assessed_at': now.millisecondsSinceEpoch,
      'created_at': now.millisecondsSinceEpoch,
    });
    await sdb.db.delete('plan', where: 'id = ?', whereArgs: [pid]);
    final ms = await sdb.db.query('milestone', where: 'plan_id = ?', whereArgs: [pid]);
    final as_ = await sdb.db.query('assessment', where: 'plan_id = ?', whereArgs: [pid]);
    expect(ms, isEmpty, reason: 'milestone 未级联删除');
    expect(as_, isEmpty, reason: 'assessment 未级联删除');
    await sdb.close();
  });
```

同时更新既有"建库后 8 张表存在"测试的期望列表（在该 test 的 `for` 循环列表里追加 `'plan', 'milestone', 'assessment'`，并把注释里的"8 张表"改成"11 张表"）。

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/study_engine && dart test test/db_test.dart`
Expected: FAIL — `plan`/`milestone`/`assessment` 表不存在；CASCADE 测试因无 FK 报错或残留行。

- [ ] **Step 3: Write minimal implementation**

Modify `packages/study_engine/lib/src/db/database_migrations.dart`：

改版本号：
```dart
const int kCurrentDbVersion = 3;
```

在 `migrateDatabase` 的 switch 内 `case 2` 后追加：
```dart
      case 3:
        _v3(batch);
        break;
```

在文件末尾追加：
```dart
/// v3：学习计划三表。只增不改既有表。
void _v3(Batch batch) {
  batch.execute('''
    CREATE TABLE plan (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      exam_date INTEGER NOT NULL,
      exam_content TEXT NOT NULL,
      target TEXT NOT NULL,
      daily_minutes INTEGER NOT NULL,
      current_level TEXT,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    )
  ''');
  batch.execute('''
    CREATE TABLE milestone (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      plan_id INTEGER NOT NULL,
      title TEXT NOT NULL,
      description TEXT NOT NULL,
      target_date INTEGER NOT NULL,
      sort_order INTEGER NOT NULL DEFAULT 0,
      status TEXT NOT NULL DEFAULT 'pending',
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      FOREIGN KEY (plan_id) REFERENCES plan(id) ON DELETE CASCADE
    )
  ''');
  batch.execute('CREATE INDEX idx_milestone_plan ON milestone(plan_id)');
  batch.execute('''
    CREATE TABLE assessment (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      plan_id INTEGER NOT NULL,
      score INTEGER,
      note TEXT,
      assessed_at INTEGER NOT NULL,
      created_at INTEGER NOT NULL,
      FOREIGN KEY (plan_id) REFERENCES plan(id) ON DELETE CASCADE
    )
  ''');
  batch.execute('CREATE INDEX idx_assessment_plan ON assessment(plan_id, assessed_at)');
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd packages/study_engine && dart test test/db_test.dart`
Expected: PASS（全部测试，含新两个 + 更新后的 8→11 表测试）。

- [ ] **Step 5: Run full engine test suite to verify no regression**

Run: `cd packages/study_engine && dart test`
Expected: PASS（所有既有测试 + 新测试）。

- [ ] **Step 6: Commit**

```bash
git add packages/study_engine/lib/src/db/database_migrations.dart packages/study_engine/test/db_test.dart
git commit -m "feat(db): v3 迁移 — plan/milestone/assessment 三表(CASCADE)"
```

---

## Task 3: PlanRepository（CRUD + 聚合）

**Files:**
- Create: `packages/study_engine/lib/src/repos/plan_repository.dart`
- Create: `packages/study_engine/test/plan_repo_test.dart`
- Modify: `packages/study_engine/lib/study_engine.dart`

**Interfaces:**
- Consumes: Task 1 三模型 + Task 2 三表。
- Produces: `PlanRepository(StudyDatabase)`，方法：
  - `Future<int> insertPlan(Plan p)`
  - `Future<Plan?> findPlanById(int id)`
  - `Future<List<Plan>> findAllPlans()`
  - `Future<void> updatePlan(Plan p)` — 刷 updated_at
  - `Future<void> deletePlan(int id)` — CASCADE 清节点和测评
  - `Future<int> addMilestone(Milestone m)`
  - `Future<List<Milestone>> findMilestonesByPlan(int planId)` — 按 sort_order 排
  - `Future<void> updateMilestone(int id, {String? title, String? description, DateTime? targetDate, int? sortOrder, String? status})` — 刷 updated_at
  - `Future<void> deleteMilestone(int id)`
  - `Future<int> addAssessment(Assessment a)`
  - `Future<List<Assessment>> findAssessmentsByPlan(int planId)` — 按 assessed_at 排
  - `Future<Assessment?> latestAssessment(int planId)` — 最近一次测评
  - `Future<PlanDetail> getPlanDetail(int planId)` — 聚合：Plan + List<Milestone> + List<Assessment>

- [ ] **Step 1: Write the failing test**

Create `packages/study_engine/test/plan_repo_test.dart`:

```dart
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';
import 'package:study_engine/study_engine.dart';

Future<StudyDatabase> _fresh() {
  sqfliteFfiInit();
  return StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
}

void main() {
  late StudyDatabase sdb;
  late PlanRepository repo;
  setUp(() async {
    sdb = await _fresh();
    repo = PlanRepository(sdb);
  });
  tearDown(() async => await sdb.close());

  Plan _plan() {
    final now = DateTime.now();
    return Plan(
      name: '考研冲刺', examDate: DateTime(2026, 12, 21), examContent: '408',
      target: '380', dailyMinutes: 180, currentLevel: '估 300 分',
      createdAt: now, updatedAt: now,
    );
  }

  test('insertPlan/findPlanById/findAllPlans', () async {
    final id = await repo.insertPlan(_plan());
    final got = await repo.findPlanById(id);
    expect(got?.name, '考研冲刺');
    expect(await repo.findAllPlans(), hasLength(1));
  });

  test('updatePlan 刷新 updated_at', () async {
    final id = await repo.insertPlan(_plan());
    final before = (await repo.findPlanById(id))!.updatedAt;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final p = (await repo.findPlanById(id))!;
    await repo.updatePlan(Plan(
      id: id, name: p.name, examDate: p.examDate, examContent: p.examContent,
      target: '360', dailyMinutes: p.dailyMinutes, currentLevel: p.currentLevel,
      createdAt: p.createdAt, updatedAt: p.createdAt,
    ));
    final after = await repo.findPlanById(id);
    expect(after?.target, '360');
    expect(after!.updatedAt.isAfter(before) || after.updatedAt == before, isTrue);
  });

  test('Milestone 增删改查按 sort_order 排', () async {
    final pid = await repo.insertPlan(_plan());
    final now = DateTime.now();
    await repo.addMilestone(Milestone(planId: pid, title: 'm2', description: 'd', targetDate: now, sortOrder: 2, createdAt: now, updatedAt: now));
    final m1Id = await repo.addMilestone(Milestone(planId: pid, title: 'm1', description: 'd', targetDate: now, sortOrder: 1, status: 'pending', createdAt: now, updatedAt: now));
    var list = await repo.findMilestonesByPlan(pid);
    expect(list.map((m) => m.title), ['m1', 'm2']);
    await repo.updateMilestone(m1Id, status: 'done');
    list = await repo.findMilestonesByPlan(pid);
    expect(list.first.status, 'done');
    await repo.deleteMilestone(m1Id);
    expect(await repo.findMilestonesByPlan(pid), hasLength(1));
  });

  test('Assessment 增查按 assessed_at 排 + latestAssessment', () async {
    final pid = await repo.insertPlan(_plan());
    final now = DateTime.now();
    await repo.addAssessment(Assessment(planId: pid, score: 300, assessedAt: DateTime(2026, 8, 6), createdAt: now));
    await repo.addAssessment(Assessment(planId: pid, score: 310, assessedAt: DateTime(2026, 8, 20), createdAt: now));
    final list = await repo.findAssessmentsByPlan(pid);
    expect(list.map((a) => a.score), [300, 310]);
    final latest = await repo.latestAssessment(pid);
    expect(latest?.score, 310);
  });

  test('getPlanDetail 聚合三表', () async {
    final pid = await repo.insertPlan(_plan());
    final now = DateTime.now();
    await repo.addMilestone(Milestone(planId: pid, title: 'm1', description: 'd', targetDate: now, createdAt: now, updatedAt: now));
    await repo.addAssessment(Assessment(planId: pid, score: 300, assessedAt: now, createdAt: now));
    final detail = await repo.getPlanDetail(pid);
    expect(detail.plan.id, pid);
    expect(detail.milestones, hasLength(1));
    expect(detail.assessments, hasLength(1));
  });

  test('deletePlan CASCADE 清节点与测评', () async {
    final pid = await repo.insertPlan(_plan());
    final now = DateTime.now();
    await repo.addMilestone(Milestone(planId: pid, title: 'm', description: 'd', targetDate: now, createdAt: now, updatedAt: now));
    await repo.addAssessment(Assessment(planId: pid, score: 300, assessedAt: now, createdAt: now));
    await repo.deletePlan(pid);
    expect(await repo.findPlanById(pid), isNull);
    expect(await repo.findMilestonesByPlan(pid), isEmpty);
    expect(await repo.findAssessmentsByPlan(pid), isEmpty);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/study_engine && dart test test/plan_repo_test.dart`
Expected: FAIL — `PlanRepository` / `PlanDetail` 未定义。

- [ ] **Step 3: Write minimal implementation**

Create `packages/study_engine/lib/src/repos/plan_repository.dart`:

```dart
import '../db/database.dart';
import '../models/plan_models.dart';

/// 计划详情聚合：Plan + 节点列表 + 测评列表。
class PlanDetail {
  final Plan plan;
  final List<Milestone> milestones;
  final List<Assessment> assessments;
  PlanDetail(this.plan, this.milestones, this.assessments);
}

class PlanRepository {
  final StudyDatabase _db;
  PlanRepository(this._db);

  // ===== Plan =====
  Future<int> insertPlan(Plan p) => _db.db.insert('plan', p.toMap());

  Future<Plan?> findPlanById(int id) async {
    final rows = await _db.db.query('plan', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : Plan.fromMap(rows.first);
  }

  Future<List<Plan>> findAllPlans() async {
    final rows = await _db.db.query('plan', orderBy: 'updated_at DESC');
    return rows.map(Plan.fromMap).toList();
  }

  /// 更新计划元信息并刷新 updated_at。
  Future<void> updatePlan(Plan p) async {
    await _db.db.update(
      'plan',
      Plan(
        id: p.id, name: p.name, examDate: p.examDate, examContent: p.examContent,
        target: p.target, dailyMinutes: p.dailyMinutes, currentLevel: p.currentLevel,
        createdAt: p.createdAt, updatedAt: DateTime.now(),
      ).toMap(),
      where: 'id = ?', whereArgs: [p.id],
    );
  }

  Future<void> deletePlan(int id) => _db.db.delete('plan', where: 'id = ?', whereArgs: [id]);

  // ===== Milestone =====
  Future<int> addMilestone(Milestone m) => _db.db.insert('milestone', m.toMap());

  Future<List<Milestone>> findMilestonesByPlan(int planId) async {
    final rows = await _db.db.query('milestone', where: 'plan_id = ?', whereArgs: [planId], orderBy: 'sort_order, target_date');
    return rows.map(Milestone.fromMap).toList();
  }

  /// 部分更新节点。仅传非 null 字段被改，并刷 updated_at。
  Future<void> updateMilestone(
    int id, {
    String? title,
    String? description,
    DateTime? targetDate,
    int? sortOrder,
    String? status,
  }) async {
    final patch = <String, Object?>{
      if (title != null) 'title': title,
      if (description != null) 'description': description,
      if (targetDate != null) 'target_date': targetDate.millisecondsSinceEpoch,
      if (sortOrder != null) 'sort_order': sortOrder,
      if (status != null) 'status': status,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    };
    await _db.db.update('milestone', patch, where: 'id = ?', whereArgs: [id]);
  }

  Future<void> deleteMilestone(int id) => _db.db.delete('milestone', where: 'id = ?', whereArgs: [id]);

  // ===== Assessment =====
  Future<int> addAssessment(Assessment a) => _db.db.insert('assessment', a.toMap());

  Future<List<Assessment>> findAssessmentsByPlan(int planId) async {
    final rows = await _db.db.query('assessment', where: 'plan_id = ?', whereArgs: [planId], orderBy: 'assessed_at');
    return rows.map(Assessment.fromMap).toList();
  }

  /// 最近一次测评（按 assessed_at 降序取首条）。无测评返回 null。
  Future<Assessment?> latestAssessment(int planId) async {
    final rows = await _db.db.query('assessment', where: 'plan_id = ?', whereArgs: [planId], orderBy: 'assessed_at DESC', limit: 1);
    return rows.isEmpty ? null : Assessment.fromMap(rows.first);
  }

  // ===== 聚合 =====
  Future<PlanDetail> getPlanDetail(int planId) async {
    final plan = await findPlanById(planId);
    if (plan == null) throw StateError('计划 id=$planId 不存在');
    final milestones = await findMilestonesByPlan(planId);
    final assessments = await findAssessmentsByPlan(planId);
    return PlanDetail(plan, milestones, assessments);
  }
}
```

Modify `packages/study_engine/lib/study_engine.dart` — 在 `export 'src/repos/chat_repository.dart';` 后追加：

```dart
export 'src/repos/plan_repository.dart';
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd packages/study_engine && dart test test/plan_repo_test.dart`
Expected: PASS（6 个测试全过）。

- [ ] **Step 5: Run full engine test suite**

Run: `cd packages/study_engine && dart test`
Expected: PASS。

- [ ] **Step 6: Commit**

```bash
git add packages/study_engine/lib/src/repos/plan_repository.dart packages/study_engine/lib/study_engine.dart packages/study_engine/test/plan_repo_test.dart
git commit -m "feat(repos): PlanRepository — CRUD + 聚合 + CASCADE"
```

---

## Task 4: Plan 工具 schema（plan_tools.dart）

**Files:**
- Create: `packages/study_engine/lib/src/agent/plan_tools.dart`
- Modify: `packages/study_engine/lib/study_engine.dart`

**Interfaces:**
- Produces: `PlanTools.planTools` — `List<Map<String, dynamic>>` 7 个工具 schema（OpenAI function calling 格式），仿 `AgentTools.studyTools`。工具名：`create_plan` / `get_plan` / `update_plan` / `add_milestone` / `update_milestone` / `delete_milestone` / `add_assessment`。

- [ ] **Step 1: Create the tool schema file**

Create `packages/study_engine/lib/src/agent/plan_tools.dart`:

```dart
/// 学习计划 Agent 工具 schema（OpenAI function calling）。7 个工具管理计划全生命周期。
class PlanTools {
  PlanTools._();

  static const createPlan = {
    'type': 'function',
    'function': {
      'name': 'create_plan',
      'description': '创建一个学习计划。必须收齐 name/exam_date/exam_content/target/daily_minutes/current_level 六项，缺任何一项要先追问用户补齐。创建后会自动把 current_level 解析成分数生成第一条测评记录作为起点。',
      'parameters': {
        'type': 'object',
        'properties': {
          'name': {'type': 'string', 'description': '计划名，如"考研冲刺"'},
          'exam_date': {'type': 'string', 'description': '考试日期，YYYY-MM-DD'},
          'exam_content': {'type': 'string', 'description': '考试内容/范围，如"政治、英语一、数学一、408"'},
          'target': {'type': 'string', 'description': '目标，如"总分 380"或"过六级"'},
          'daily_minutes': {'type': 'integer', 'description': '每日可学习时长（分钟）'},
          'current_level': {'type': 'string', 'description': '当前自评水平，如"做真题估 300 分，数学最弱"'},
        },
        'required': ['name', 'exam_date', 'exam_content', 'target', 'daily_minutes', 'current_level'],
      },
    },
  };

  static const getPlan = {
    'type': 'function',
    'function': {
      'name': 'get_plan',
      'description': '获取计划完整结构：元信息 + 所有里程碑节点 + 所有测评记录。用于了解当前计划全貌、为调整做判断。',
      'parameters': {
        'type': 'object',
        'properties': {
          'plan_id': {'type': 'integer', 'description': '计划 id'},
        },
        'required': ['plan_id'],
      },
    },
  };

  static const updatePlan = {
    'type': 'function',
    'function': {
      'name': 'update_plan',
      'description': '更新计划元信息（名称/考试日期/内容/目标/每日时长）。只传需要改的字段。改目标时建议联动调整节点分数预期。',
      'parameters': {
        'type': 'object',
        'properties': {
          'plan_id': {'type': 'integer', 'description': '计划 id'},
          'name': {'type': 'string', 'description': '新计划名（可选）'},
          'exam_date': {'type': 'string', 'description': '新考试日期 YYYY-MM-DD（可选）'},
          'exam_content': {'type': 'string', 'description': '新考试内容（可选）'},
          'target': {'type': 'string', 'description': '新目标（可选）'},
          'daily_minutes': {'type': 'integer', 'description': '新每日时长分钟（可选）'},
        },
        'required': ['plan_id'],
      },
    },
  };

  static const addMilestone = {
    'type': 'function',
    'function': {
      'name': 'add_milestone',
      'description': '给计划新增一个里程碑节点。description 要写清达到什么程度算完成。',
      'parameters': {
        'type': 'object',
        'properties': {
          'plan_id': {'type': 'integer', 'description': '计划 id'},
          'title': {'type': 'string', 'description': '节点名，如"数学基础过完"'},
          'description': {'type': 'string', 'description': '完成标志，如"高数+线代基础课听完，能独立做基础题"'},
          'target_date': {'type': 'string', 'description': '目标完成日期 YYYY-MM-DD'},
          'sort_order': {'type': 'integer', 'description': '顺序，默认0'},
        },
        'required': ['plan_id', 'title', 'description', 'target_date'],
      },
    },
  };

  static const updateMilestone = {
    'type': 'function',
    'function': {
      'name': 'update_milestone',
      'description': '更新里程碑节点（标题/描述/日期/顺序/状态）。status 只能是 pending 或 done。只传需要改的字段。',
      'parameters': {
        'type': 'object',
        'properties': {
          'milestone_id': {'type': 'integer', 'description': '节点 id'},
          'title': {'type': 'string', 'description': '新标题（可选）'},
          'description': {'type': 'string', 'description': '新描述（可选）'},
          'target_date': {'type': 'string', 'description': '新目标日期 YYYY-MM-DD（可选）'},
          'sort_order': {'type': 'integer', 'description': '新顺序（可选）'},
          'status': {'type': 'string', 'enum': ['pending', 'done'], 'description': '新状态（可选）'},
        },
        'required': ['milestone_id'],
      },
    },
  };

  static const deleteMilestone = {
    'type': 'function',
    'function': {
      'name': 'delete_milestone',
      'description': '删除一个里程碑节点。删除前应向用户确认一句。',
      'parameters': {
        'type': 'object',
        'properties': {
          'milestone_id': {'type': 'integer', 'description': '节点 id'},
        },
        'required': ['milestone_id'],
      },
    },
  };

  static const addAssessment = {
    'type': 'function',
    'function': {
      'name': 'add_assessment',
      'description': '记录一次测评（用户做真题/模考后报分时调用）。score 为分数，note 为备注（可选）。assessed_at 不传默认今天。',
      'parameters': {
        'type': 'object',
        'properties': {
          'plan_id': {'type': 'integer', 'description': '计划 id'},
          'score': {'type': 'integer', 'description': '分数。无法量化时传 null 并在 note 里记录定性进展'},
          'note': {'type': 'string', 'description': '备注（可选），如"线代大题崩了"'},
          'assessed_at': {'type': 'string', 'description': '测评日期 YYYY-MM-DD，不传默认今天（可选）'},
        },
        'required': ['plan_id', 'score'],
      },
    },
  };

  static const planTools = [
    createPlan, getPlan, updatePlan, addMilestone, updateMilestone, deleteMilestone, addAssessment,
  ];
}
```

- [ ] **Step 2: Add barrel export**

Modify `packages/study_engine/lib/study_engine.dart` — 在 `export 'src/agent/agent_tools.dart';` 后追加：

```dart
export 'src/agent/plan_tools.dart';
```

- [ ] **Step 3: Verify it compiles**

Run: `cd packages/study_engine && dart analyze`
Expected: No issues.

- [ ] **Step 4: Commit**

```bash
git add packages/study_engine/lib/src/agent/plan_tools.dart packages/study_engine/lib/study_engine.dart
git commit -m "feat(agent): PlanTools — 7 工具 schema"
```

---

## Task 5: PlanScenario（7 工具执行 + 系统提示词）

**Files:**
- Create: `packages/study_engine/lib/src/agent/scenarios/plan_scenario.dart`
- Create: `packages/study_engine/test/plan_scenario_integration_test.dart`
- Modify: `packages/study_engine/lib/study_engine.dart`

**Interfaces:**
- Consumes: Task 3 `PlanRepository` + Task 4 `PlanTools` + 既有 `AgentScenario` 抽象 / `AgentScenarioContext` / `AgentMemoryRepository`。
- Produces: `PlanScenario` implements `AgentScenario`，`id='plan'`，`tools=PlanTools.planTools`。`executeTool` 分发 7 工具。`buildSystemPrompt(ctx)` 读 `ctx.extra['today']`（DateTime）、`ctx.extra['plan_summary']`（String，APP 层注入，可空）拼提示词。
  - `create_plan` 内部：插 Plan → 从 `current_level` 抽分数（正则 `\d+`）→ 插首条 Assessment（抽不到分数则 score=null、note=current_level）→ 返回新 plan_id。
  - 工具返回 JSON 字符串（仿 `StudyScenario._getTopic` 的 `jsonEncode` 风格）。

- [ ] **Step 1: Write the failing test**

Create `packages/study_engine/test/plan_scenario_integration_test.dart`:

```dart
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';
import 'package:study_engine/study_engine.dart';

Future<StudyDatabase> _fresh() {
  sqfliteFfiInit();
  return StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
}

PlanScenario newScenario(StudyDatabase sdb) => PlanScenario(
      plans: PlanRepository(sdb),
      memories: AgentMemoryRepository(sdb),
    );

void main() {
  setUpAll(sqfliteFfiInit);

  test('场景1 create_plan 收齐后落库 + 自动生成首条测评', () async {
    final sdb = await _fresh();
    final scenario = newScenario(sdb);
    final repo = PlanRepository(sdb);

    final result = await scenario.executeTool('create_plan', {
      'name': '考研冲刺',
      'exam_date': '2026-12-21',
      'exam_content': '408',
      'target': '380',
      'daily_minutes': 180,
      'current_level': '做真题估 300 分，数学最弱',
    });
    expect(result, contains('已创建'));

    final plans = await repo.findAllPlans();
    expect(plans, hasLength(1));
    final pid = plans.first.id!;
    // current_level "估 300 分" 抽出 300 作为起点测评
    final assessments = await repo.findAssessmentsByPlan(pid);
    expect(assessments, hasLength(1));
    expect(assessments.first.score, 300);
    await sdb.close();
  });

  test('场景2 create_plan current_level 抽不到分数时 score=null', () async {
    final sdb = await _fresh();
    final scenario = newScenario(sdb);
    final repo = PlanRepository(sdb);

    await scenario.executeTool('create_plan', {
      'name': '六级', 'exam_date': '2026-12-14', 'exam_content': '六级',
      'target': '过六级', 'daily_minutes': 60, 'current_level': '感觉听力还行，阅读差',
    });
    final pid = (await repo.findAllPlans()).first.id!;
    final a = (await repo.findAssessmentsByPlan(pid)).first;
    expect(a.score, isNull);
    expect(a.note, contains('听力'));
    await sdb.close();
  });

  test('场景3 create_plan 缺参数不落库（防御）', () async {
    final sdb = await _fresh();
    final scenario = newScenario(sdb);
    final repo = PlanRepository(sdb);

    final result = await scenario.executeTool('create_plan', {
      'name': '考研', 'exam_date': '2026-12-21',
      // 缺 exam_content/target/daily_minutes/current_level
    });
    expect(result, contains('缺少'));
    expect(await repo.findAllPlans(), isEmpty);
    await sdb.close();
  });

  test('场景4 add_milestone + get_plan 完整返回', () async {
    final sdb = await _fresh();
    final scenario = newScenario(sdb);
    final repo = PlanRepository(sdb);

    final createResult = await scenario.executeTool('create_plan', {
      'name': '考研', 'exam_date': '2026-12-21', 'exam_content': '408',
      'target': '380', 'daily_minutes': 180, 'current_level': '估 300 分',
    });
    final pid = (await repo.findAllPlans()).first.id!;

    await scenario.executeTool('add_milestone', {
      'plan_id': pid, 'title': '数学基础', 'description': '高数线代基础课', 'target_date': '2026-09-30',
    });
    await scenario.executeTool('add_milestone', {
      'plan_id': pid, 'title': '真题一轮', 'description': '全科真题刷完', 'target_date': '2026-11-10',
    });

    final detail = await scenario.executeTool('get_plan', {'plan_id': pid});
    expect(detail, contains('数学基础'));
    expect(detail, contains('真题一轮'));
    expect(detail, contains('300'));
    await sdb.close();
  });

  test('场景5 update_milestone 状态切换 + 非法状态拒绝', () async {
    final sdb = await _fresh();
    final scenario = newScenario(sdb);
    final repo = PlanRepository(sdb);

    await scenario.executeTool('create_plan', {
      'name': '考研', 'exam_date': '2026-12-21', 'exam_content': '408',
      'target': '380', 'daily_minutes': 180, 'current_level': '估 300 分',
    });
    final pid = (await repo.findAllPlans()).first.id!;
    final msId = await repo.addMilestone(Milestone(
      planId: pid, title: 'm1', description: 'd', targetDate: DateTime(2026, 9, 30),
      createdAt: DateTime.now(), updatedAt: DateTime.now(),
    ));

    await scenario.executeTool('update_milestone', {'milestone_id': msId, 'status': 'done'});
    expect((await repo.findMilestonesByPlan(pid)).first.status, 'done');

    final bad = await scenario.executeTool('update_milestone', {'milestone_id': msId, 'status': 'xxx'});
    expect(bad, contains('status'));
    await sdb.close();
  });

  test('场景6 delete_milestone + add_assessment', () async {
    final sdb = await _fresh();
    final scenario = newScenario(sdb);
    final repo = PlanRepository(sdb);

    await scenario.executeTool('create_plan', {
      'name': '考研', 'exam_date': '2026-12-21', 'exam_content': '408',
      'target': '380', 'daily_minutes': 180, 'current_level': '估 300 分',
    });
    final pid = (await repo.findAllPlans()).first.id!;
    final msId = await repo.addMilestone(Milestone(
      planId: pid, title: 'm1', description: 'd', targetDate: DateTime(2026, 9, 30),
      createdAt: DateTime.now(), updatedAt: DateTime.now(),
    ));

    await scenario.executeTool('delete_milestone', {'milestone_id': msId});
    expect(await repo.findMilestonesByPlan(pid), isEmpty);

    final ar = await scenario.executeTool('add_assessment', {
      'plan_id': pid, 'score': 310, 'note': '线代崩了',
    });
    expect(ar, contains('310'));
    final list = await repo.findAssessmentsByPlan(pid);
    expect(list, hasLength(2)); // 起点 300 + 新 310
    expect(list.last.score, 310);
    await sdb.close();
  });

  test('场景7 buildSystemPrompt 含今天日期与计划概要', () async {
    final sdb = await _fresh();
    final scenario = newScenario(sdb);

    final ctx = AgentScenarioContext(extra: {
      'today': DateTime(2026, 8, 10),
      'plan_summary': '计划：考研冲刺，考试 2026-12-21，目标 380',
    });
    final prompt = scenario.buildSystemPrompt(ctx);
    expect(prompt, contains('2026-08-10'));
    expect(prompt, contains('考研冲刺'));
    expect(prompt, contains('create_plan'));
    await sdb.close();
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/study_engine && dart test test/plan_scenario_integration_test.dart`
Expected: FAIL — `PlanScenario` 未定义。

- [ ] **Step 3: Write minimal implementation**

Create `packages/study_engine/lib/src/agent/scenarios/plan_scenario.dart`:

```dart
import 'dart:convert';
import '../../models/models.dart';
import '../../models/plan_models.dart';
import '../../repos/agent_memory_repository.dart';
import '../../repos/plan_repository.dart';
import '../agent_scenario.dart';
import '../agent_tools.dart' show MemoryPatchResult;
import '../plan_tools.dart';

/// 学习计划场景：7 工具管理计划全生命周期，记忆来自 agent_memory 表（scenario_id='plan'）。
class PlanScenario implements AgentScenario {
  final PlanRepository plans;
  final AgentMemoryRepository memories;

  PlanScenario({required this.plans, required this.memories});

  @override String get id => 'plan';
  @override String get displayName => '学习计划';
  @override List<Map<String, dynamic>> get tools => PlanTools.planTools;

  @override
  String buildSystemPrompt(AgentScenarioContext ctx) {
    final today = ctx.extra['today'] as DateTime?;
    final todayStr = today != null
        ? '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}'
        : '（未知）';
    final planSummary = ctx.extra['plan_summary'] as String? ?? '（无当前计划，用户可能要新建）';
    final mem = _memCache;
    final memBlock = mem.isEmpty ? '（暂无）' : mem.asMap().entries.map((e) => '[${e.key + 1}] ${e.value}').join('\n');
    return '''你是学习计划助手 AI。职责：帮用户把考试目标拆成可执行的里程碑节点，跟踪周期测评，画进步曲线，并根据进度随时调整计划。

## 当前时间
今天是 $todayStr。

## 创建计划（create_plan）必须收齐
- name：计划名
- exam_date：考试日期（YYYY-MM-DD）
- exam_content：考试内容/范围
- target：目标（分数/院校/通过等）
- daily_minutes：每日可学习时长（分钟）
- current_level：当前自评水平（最近做真题能考多少分，哪块弱）
缺任何一项都要先追问用户补齐，不要瞎猜。收齐后再 create_plan。

## 拆节点原则
- 按考试日期倒推，结合每日时长和当前差距排期。
- 薄弱项节点排前。
- 每个节点要有明确的"完成标志"（description 写清达到什么程度算过）。
- 节点数 4-8 个为宜，太细碎用户跟不上，太粗等于没拆。

## 调整原则
- 用户报进度落后/超前时，对照 get_plan 的节点和测评重排后续节点。
- 改目标时联动调整节点的分数预期。
- 高危操作（删节点）执行前向用户确认一句。

## 测评
- 用户提到做了真题/模考并报分时，用 add_assessment 录入。
- 鼓励用户定期测评，对照曲线看趋势。

## 当前计划上下文
$planSummary

## 经验记忆
$memBlock''';
  }

  List<String> _memCache = const [];

  @override
  Future<String> executeTool(String name, Map<String, dynamic> args,
      {void Function(String p)? onProgress, String? toolCallId}) async {
    switch (name) {
      case 'create_plan':
        return _createPlan(args);
      case 'get_plan':
        return _getPlan(args['plan_id'] as int);
      case 'update_plan':
        return _updatePlan(args);
      case 'add_milestone':
        return _addMilestone(args);
      case 'update_milestone':
        return _updateMilestone(args);
      case 'delete_milestone':
        return _deleteMilestone(args['milestone_id'] as int);
      case 'add_assessment':
        return _addAssessment(args);
      default:
        return '未知工具: $name';
    }
  }

  DateTime _parseDate(String s) => DateTime.parse(s);

  Future<String> _createPlan(Map<String, dynamic> args) async {
    final name = args['name'] as String?;
    final examDate = args['exam_date'] as String?;
    final examContent = args['exam_content'] as String?;
    final target = args['target'] as String?;
    final dailyMinutes = args['daily_minutes'] as int?;
    final currentLevel = args['current_level'] as String?;
    final missing = <String>[];
    if (name == null) missing.add('name');
    if (examDate == null) missing.add('exam_date');
    if (examContent == null) missing.add('exam_content');
    if (target == null) missing.add('target');
    if (dailyMinutes == null) missing.add('daily_minutes');
    if (currentLevel == null) missing.add('current_level');
    if (missing.isNotEmpty) {
      return '缺少必填字段: ${missing.join(', ')}。请向用户追问补齐后再创建。';
    }
    final now = DateTime.now();
    final planId = await plans.insertPlan(Plan(
      name: name!,
      examDate: _parseDate(examDate!),
      examContent: examContent!,
      target: target!,
      dailyMinutes: dailyMinutes!,
      currentLevel: currentLevel,
      createdAt: now,
      updatedAt: now,
    ));
    // 从 current_level 抽分数作为起点测评
    final score = _extractScore(currentLevel!);
    await plans.addAssessment(Assessment(
      planId: planId,
      score: score,
      note: score == null ? currentLevel : null,
      assessedAt: now,
      createdAt: now,
    ));
    return jsonEncode({'ok': true, 'plan_id': planId, 'message': '已创建计划「$name」(id=$planId)，起点测评 $score 分'});
  }

  /// 从文本抽取第一个整数作为分数。抽不到返回 null。
  int? _extractScore(String text) {
    final m = RegExp(r'\d+').firstMatch(text);
    return m == null ? null : int.tryParse(m.group(0)!);
  }

  Future<String> _getPlan(int planId) async {
    final detail = await plans.getPlanDetail(planId);
    final msList = detail.milestones.map((m) => {
          'id': m.id, 'title': m.title, 'description': m.description,
          'target_date': '${m.targetDate.year}-${m.targetDate.month.toString().padLeft(2, '0')}-${m.targetDate.day.toString().padLeft(2, '0')}',
          'status': m.status, 'sort_order': m.sortOrder,
        }).toList();
    final aList = detail.assessments.map((a) => {
          'id': a.id, 'score': a.score, 'note': a.note,
          'assessed_at': '${a.assessedAt.year}-${a.assessedAt.month.toString().padLeft(2, '0')}-${a.assessedAt.day.toString().padLeft(2, '0')}',
        }).toList();
    return jsonEncode({
      'plan': {
        'id': detail.plan.id, 'name': detail.plan.name,
        'exam_date': '${detail.plan.examDate.year}-${detail.plan.examDate.month.toString().padLeft(2, '0')}-${detail.plan.examDate.day.toString().padLeft(2, '0')}',
        'exam_content': detail.plan.examContent, 'target': detail.plan.target,
        'daily_minutes': detail.plan.dailyMinutes, 'current_level': detail.plan.currentLevel,
      },
      'milestones': msList,
      'assessments': aList,
    });
  }

  Future<String> _updatePlan(Map<String, dynamic> args) async {
    final pid = args['plan_id'] as int;
    final existing = await plans.findPlanById(pid);
    if (existing == null) return '计划 id=$pid 不存在';
    await plans.updatePlan(Plan(
      id: pid,
      name: args['name'] as String? ?? existing.name,
      examDate: args['exam_date'] != null ? _parseDate(args['exam_date'] as String) : existing.examDate,
      examContent: args['exam_content'] as String? ?? existing.examContent,
      target: args['target'] as String? ?? existing.target,
      dailyMinutes: args['daily_minutes'] as int? ?? existing.dailyMinutes,
      currentLevel: existing.currentLevel,
      createdAt: existing.createdAt,
      updatedAt: existing.createdAt,
    ));
    return '已更新计划「${existing.name}」';
  }

  Future<String> _addMilestone(Map<String, dynamic> args) async {
    final pid = args['plan_id'] as int;
    final existing = await plans.findPlanById(pid);
    if (existing == null) return '计划 id=$pid 不存在';
    final now = DateTime.now();
    final id = await plans.addMilestone(Milestone(
      planId: pid,
      title: args['title'] as String,
      description: args['description'] as String,
      targetDate: _parseDate(args['target_date'] as String),
      sortOrder: (args['sort_order'] as int?) ?? 0,
      createdAt: now,
      updatedAt: now,
    ));
    return '已添加节点「${args['title']}」(id=$id)';
  }

  Future<String> _updateMilestone(Map<String, dynamic> args) async {
    final mid = args['milestone_id'] as int;
    final status = args['status'] as String?;
    if (status != null && status != 'pending' && status != 'done') {
      return 'status 必须是 pending 或 done，收到: $status';
    }
    await plans.updateMilestone(
      mid,
      title: args['title'] as String?,
      description: args['description'] as String?,
      targetDate: args['target_date'] != null ? _parseDate(args['target_date'] as String) : null,
      sortOrder: args['sort_order'] as int?,
      status: status,
    );
    return '已更新节点 id=$mid';
  }

  Future<String> _deleteMilestone(int milestoneId) async {
    await plans.deleteMilestone(milestoneId);
    return '已删除节点 id=$milestoneId';
  }

  Future<String> _addAssessment(Map<String, dynamic> args) async {
    final pid = args['plan_id'] as int;
    final existing = await plans.findPlanById(pid);
    if (existing == null) return '计划 id=$pid 不存在';
    final now = DateTime.now();
    final assessedAt = args['assessed_at'] != null ? _parseDate(args['assessed_at'] as String) : now;
    final score = args['score'] as int?;
    final id = await plans.addAssessment(Assessment(
      planId: pid,
      score: score,
      note: args['note'] as String?,
      assessedAt: assessedAt,
      createdAt: now,
    ));
    return jsonEncode({'ok': true, 'assessment_id': id, 'score': score});
  }

  @override
  Future<String?> onNoToolCalls(List<ChatMessage> messages) async => null;

  @override
  Future<List<String>> getMemories() async {
    _memCache = (await memories.queryByScenario(id)).map((m) => m.content).toList();
    return _memCache;
  }

  @override
  Future<MemoryPatchResult> patchMemory(int? index, String newText) async {
    final all = await memories.queryByScenario(id);
    if (index == null) {
      await memories.add(id, newText);
      return MemoryPatchResult(true, '已新增记忆');
    }
    final i = index - 1;
    if (i < 0 || i >= all.length) {
      return MemoryPatchResult(false, '编号越界，可用范围 1..${all.length}');
    }
    await memories.update(all[i].id!, newText);
    return MemoryPatchResult(true, '已更新记忆 $index');
  }

  @override
  Future<void> cleanup() async {}
}
```

> 注意：`MemoryPatchResult` 当前定义在 `agent_scenario.dart`，但 `study_scenario.dart` 用 `import '../agent_tools.dart' show MemoryPatchResult;` 导入。实现时若 analyzer 报 `MemoryPatchResult` 未导出，改从 `agent_scenario.dart` 导入。验证以 Step 4 的 `dart analyze` 为准。

Modify `packages/study_engine/lib/study_engine.dart` — 在 `export 'src/agent/scenarios/study_scenario.dart';` 后追加：

```dart
export 'src/agent/scenarios/plan_scenario.dart';
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd packages/study_engine && dart test test/plan_scenario_integration_test.dart`
Expected: PASS（7 个测试全过）。

- [ ] **Step 5: Run full engine test suite + analyze**

Run: `cd packages/study_engine && dart test && dart analyze`
Expected: 全部测试 PASS，analyze 无 issue。若 `MemoryPatchResult` 导入报错，按上面注释调整 import 来源后重跑。

- [ ] **Step 6: Commit**

```bash
git add packages/study_engine/lib/src/agent/scenarios/plan_scenario.dart packages/study_engine/lib/study_engine.dart packages/study_engine/test/plan_scenario_integration_test.dart
git commit -m "feat(scenario): PlanScenario — 7 工具执行 + 系统提示词(含日期/计划概要注入)"
```

---

## Task 6: APP 层 PlanSession + Providers

**Files:**
- Create: `study_buddy/lib/core/providers/plan_provider.dart`

**Interfaces:**
- Consumes: Task 3 `PlanRepository` + Task 5 `PlanScenario` + 既有 `databaseProvider` / `LlmConfigRepository` / `LlmProvider` / `AgentLoop`。
- Produces:
  - `planRepositoryProvider`（Provider<PlanRepository>）
  - `planListProvider`（FutureProvider<List<Plan>>）
  - `planDetailProvider`（FutureProvider.family<PlanDetail, int>）
  - `planSessionProvider`（Provider<PlanSession>），`PlanSession.run(messages, {int? planId, required DateTime today})` 返回 `Stream<AgentEvent>`。内部：取 `vision:false` 默认 LlmConfig → 构造 PlanScenario → 若有 planId 则查 `getPlanDetail` 拼 `plan_summary` → 注入 `AgentScenarioContext.extra` → AgentLoop.run。

- [ ] **Step 1: Create the provider file**

Create `study_buddy/lib/core/providers/plan_provider.dart`:

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:study_engine/study_engine.dart';

import 'database_provider.dart';

/// 异步获取 PlanRepository（等待 db 就绪）。
final planRepositoryAsyncProvider = FutureProvider<PlanRepository>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  return PlanRepository(db);
});

/// 计划列表（首页用）。
final planListProvider = FutureProvider<List<Plan>>((ref) async {
  final repo = await ref.watch(planRepositoryAsyncProvider.future);
  return repo.findAllPlans();
});

/// 计划详情聚合（详情页用）。
final planDetailProvider = FutureProvider.family<PlanDetail, int>((ref, planId) async {
  final repo = await ref.watch(planRepositoryAsyncProvider.future);
  return repo.getPlanDetail(planId);
});

/// APP 层计划 agent 调用入口：构造 PlanScenario + AgentLoop，注入当前 plan 概要与日期。
///
/// 取 vision:false 默认 LlmConfig（计划场景不需要视觉）。
class PlanSession {
  PlanSession(this._ref);
  final Ref _ref;

  /// 运行计划 agent。planId 为空时是"新建模式"，非空时注入该计划概要到 system prompt。
  Future<Stream<AgentEvent>> run(
    List<ChatMessage> messages, {
    int? planId,
    required DateTime today,
  }) async {
    final db = await _ref.read(databaseProvider.future);
    final llmConfigs = LlmConfigRepository(db);
    final cfg = await llmConfigs.getDefault(vision: false);
    if (cfg == null) {
      throw StateError(
        '未配置默认 LLM。请先在 llm_config 表中添加 is_default=1 的记录。',
      );
    }
    final plans = PlanRepository(db);
    final memories = AgentMemoryRepository(db);

    String planSummary;
    if (planId != null) {
      final detail = await plans.getPlanDetail(planId);
      final msBlock = detail.milestones.map((m) => '- ${m.targetDate.year}-${m.targetDate.month.toString().padLeft(2, '0')}-${m.targetDate.day.toString().padLeft(2, '0')} ${m.title} [${m.status}]').join('\n');
      final lastA = detail.assessments.isNotEmpty ? detail.assessments.last : null;
      planSummary = '计划：${detail.plan.name}（id=${detail.plan.id}）\n'
          '考试：${detail.plan.examDate.year}-${detail.plan.examDate.month.toString().padLeft(2, '0')}-${detail.plan.examDate.day.toString().padLeft(2, '0')}，目标：${detail.plan.target}\n'
          '每日时长：${detail.plan.dailyMinutes} 分钟\n'
          '节点：\n$msBlock\n'
          '最近测评：${lastA?.score ?? "无"}${lastA?.note != null ? "（${lastA!.note}）" : ""}';
    } else {
      planSummary = '（用户尚未指定计划，可能是新建场景。请收齐信息后 create_plan。）';
    }

    final llm = LlmProvider(config: cfg);
    final scenario = PlanScenario(plans: plans, memories: memories);
    final loop = AgentLoop(llm: llm, scenario: scenario);
    return loop.run(messages, context: AgentScenarioContext(extra: {
      'today': today,
      'plan_summary': planSummary,
    }));
  }
}

final planSessionProvider = Provider<PlanSession>((ref) {
  return PlanSession(ref);
});
```

- [ ] **Step 2: Verify it compiles**

Run: `cd study_buddy && dart analyze lib/core/providers/plan_provider.dart`
Expected: No issues.

- [ ] **Step 3: Commit**

```bash
git add study_buddy/lib/core/providers/plan_provider.dart
git commit -m "feat(app): PlanSession + 计划 providers(注入日期/计划概要)"
```

---

## Task 7: 进步曲线 widget（CustomPainter）

**Files:**
- Create: `study_buddy/lib/features/plan/progress_chart.dart`

**Interfaces:**
- Consumes: Task 1 `Assessment` 模型 + `Plan.target`（解析目标线）。
- Produces: `ProgressChart` widget — `ProgressChart({required List<Assessment> assessments, required int? targetScore})`。画分数折线 + 目标虚线。无 score 数据点跳过。单点显示为单点。空数据显示空态文字。

- [ ] **Step 1: Create the chart widget**

Create `study_buddy/lib/features/plan/progress_chart.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:study_engine/study_engine.dart';

/// 进步曲线：分数折线 + 目标虚线。CustomPainter 手绘，不引第三方图表库。
class ProgressChart extends StatelessWidget {
  const ProgressChart({
    super.key,
    required this.assessments,
    this.targetScore,
  });

  final List<Assessment> assessments;
  final int? targetScore;

  @override
  Widget build(BuildContext context) {
    final scored = assessments.where((a) => a.score != null).toList();
    if (scored.isEmpty) {
      return Container(
        height: 160,
        alignment: Alignment.center,
        child: Text('还没有可量化的测评记录\n记一次测评看进步曲线吧', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey.shade600)),
      );
    }
    return SizedBox(
      height: 160,
      child: CustomPaint(
        size: Size.infinite,
        painter: _ChartPainter(scored: scored, targetScore: targetScore),
      ),
    );
  }
}

class _ChartPainter extends CustomPainter {
  _ChartPainter({required this.scored, required this.targetScore});
  final List<Assessment> scored;
  final int? targetScore;

  @override
  void paint(Canvas canvas, Size size) {
    final scores = scored.map((a) => a.score!).toList();
    final minScore = scores.reduce((a, b) => a < b ? a : b);
    final maxScore = scores.reduce((a, b) => a > b ? a : b);
    var lo = minScore.toDouble();
    var hi = maxScore.toDouble();
    if (targetScore != null) {
      lo = lo < targetScore! ? lo : targetScore!.toDouble();
      hi = hi > targetScore! ? hi : targetScore!.toDouble();
    }
    // 留 10% 边距避免顶底贴边
    final span = (hi - lo) == 0 ? 1.0 : (hi - lo) * 1.2;
    final center = (hi + lo) / 2;
    lo = center - span / 2;
    hi = center + span / 2;

    final padL = 40.0, padR = 12.0, padT = 12.0, padB = 24.0;
    final w = size.width - padL - padR;
    final h = size.height - padT - padB;

    double x(int i) => padL + (scored.length == 1 ? w / 2 : w * i / (scored.length - 1));
    double y(int score) => padT + h * (1 - (score - lo) / (hi - lo));

    // 目标虚线
    if (targetScore != null) {
      final ty = y(targetScore!);
      final dashPaint = Paint()
        ..color = Colors.deepPurple.withValues(alpha: 0.5)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1;
      const dashW = 5.0, gap = 4.0;
      var dx = padL;
      while (dx < size.width - padR) {
        canvas.drawLine(Offset(dx, ty), Offset(dx + dashW, ty), dashPaint);
        dx += dashW + gap;
      }
      final tp = TextPainter(text: TextSpan('目标 $targetScore', style: TextStyle(fontSize: 10, color: Colors.deepPurple)), textDirection: TextDirection.ltr);
      tp.layout();
      tp.paint(canvas, Offset(size.width - padR - tp.width - 2, ty - tp.height - 2));
    }

    // 折线
    final linePaint = Paint()
      ..color = Colors.deepPurple
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final path = Path();
    for (var i = 0; i < scored.length; i++) {
      final p = Offset(x(i), y(scores[i]));
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
      // 数据点
      canvas.drawCircle(p, 3, Paint()..color = Colors.deepPurple);
    }
    canvas.drawPath(path, linePaint);

    // 日期标签（首尾）
    final labelStyle = TextStyle(fontSize: 9, color: Colors.grey.shade700);
    for (final i in [0, scored.length - 1]) {
      final a = scored[i];
      final label = '${a.assessedAt.month}/${a.assessedAt.day}';
      final tp = TextPainter(text: TextSpan(label, style: labelStyle), textDirection: TextDirection.ltr);
      tp.layout();
      tp.paint(canvas, Offset(x(i) - tp.width / 2, size.height - padB + 4));
    }
  }

  @override
  bool shouldRepaint(covariant _ChartPainter old) =>
      old.scored != scored || old.targetScore != targetScore;
}
```

- [ ] **Step 2: Verify it compiles**

Run: `cd study_buddy && dart analyze lib/features/plan/progress_chart.dart`
Expected: No issues.

- [ ] **Step 3: Commit**

```bash
git add study_buddy/lib/features/plan/progress_chart.dart
git commit -m "feat(plan): ProgressChart — CustomPainter 手绘分数曲线+目标虚线"
```

---

## Task 8: 录分弹窗

**Files:**
- Create: `study_buddy/lib/features/plan/assessment_entry_sheet.dart`

**Interfaces:**
- Consumes: Task 3 `PlanRepository`（经 `planRepositoryAsyncProvider`）。
- Produces: `showAssessmentEntry(BuildContext, int planId)` 函数 + `_AssessmentEntrySheet` widget。字段：分数（必填数值）、备注（可选）、日期（默认今天可改）。本地校验后调 `repo.addAssessment`，返回 bool 表示是否已录入（调用方据此刷新 provider）。

- [ ] **Step 1: Create the sheet**

Create `study_buddy/lib/features/plan/assessment_entry_sheet.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:study_engine/study_engine.dart';

import '../../core/providers/plan_provider.dart';

/// 弹出录分弹窗。返回 true 表示已录入（调用方应刷新 planDetailProvider）。
Future<bool?> showAssessmentEntry(BuildContext context, int planId) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _AssessmentEntrySheet(planId: planId),
  );
}

class _AssessmentEntrySheet extends ConsumerStatefulWidget {
  const _AssessmentEntrySheet({required this.planId});
  final int planId;

  @override
  ConsumerState<_AssessmentEntrySheet> createState() => _AssessmentEntrySheetState();
}

class _AssessmentEntrySheetState extends ConsumerState<_AssessmentEntrySheet> {
  final _scoreCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();
  DateTime _date = DateTime.now();
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _scoreCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final raw = _scoreCtrl.text.trim();
    final score = int.tryParse(raw);
    if (raw.isEmpty || score == null) {
      setState(() => _error = '请输入有效分数');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final repo = await ref.read(planRepositoryAsyncProvider.future);
    await repo.addAssessment(Assessment(
      planId: widget.planId,
      score: score,
      note: _noteCtrl.text.trim().isEmpty ? null : _noteCtrl.text.trim(),
      assessedAt: _date,
      createdAt: DateTime.now(),
    ));
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    return Padding(
      padding: EdgeInsets.only(left: 16, right: 16, top: 12, bottom: mq.viewInsets.bottom + 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(width: 40, height: 4, margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(color: Colors.grey.shade400, borderRadius: BorderRadius.circular(2))),
          ),
          const Text('记录测评', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          TextField(
            controller: _scoreCtrl,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: '分数', border: OutlineInputBorder(), isDense: true),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _noteCtrl,
            decoration: const InputDecoration(labelText: '备注（可选）', border: OutlineInputBorder(), isDense: true),
            maxLines: 2,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text('日期：${_date.year}-${_date.month.toString().padLeft(2, '0')}-${_date.day.toString().padLeft(2, '0')}'),
              const SizedBox(width: 8),
              TextButton.icon(
                icon: const Icon(Icons.calendar_today, size: 16),
                label: const Text('改'),
                onPressed: _saving
                    ? null
                    : () async {
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: _date,
                          firstDate: DateTime(2020),
                          lastDate: DateTime(2100),
                        );
                        if (picked != null) setState(() => _date = picked);
                      },
              ),
            ],
          ),
          if (_error != null)
            Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: TextStyle(color: Colors.red.shade900, fontSize: 12))),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: Text(_saving ? '保存中...' : '保存'),
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `cd study_buddy && dart analyze lib/features/plan/assessment_entry_sheet.dart`
Expected: No issues.

- [ ] **Step 3: Commit**

```bash
git add study_buddy/lib/features/plan/assessment_entry_sheet.dart
git commit -m "feat(plan): AssessmentEntrySheet — 手动录分弹窗"
```

---

## Task 9: AI 对话弹窗（PlanChatSheet）

**Files:**
- Create: `study_buddy/lib/features/plan/plan_chat_sheet.dart`

**Interfaces:**
- Consumes: Task 6 `planSessionProvider` + 既有 `AgentEvent` 流。
- Produces: `showPlanChat(BuildContext, {int? planId, String? planName})` 函数 + `_PlanChatSheet` widget。两种模式：planId 为空=新建模式，非空=调整模式。流式监听 `AgentEvent`，展示 AI 回复 + 工具调用轨迹。检测到 `create_plan` 工具返回含 `plan_id` 时，关闭弹窗并跳转 `/plan/<id>`（通过回调或 GoRouter）。

- [ ] **Step 1: Create the chat sheet**

Create `study_buddy/lib/features/plan/plan_chat_sheet.dart`:

```dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:study_engine/study_engine.dart';

import '../../core/providers/plan_provider.dart';

/// 弹出计划 AI 对话。planId 为空=新建模式，非空=调整模式。
/// 新建模式下 create_plan 成功后跳转 /plan/:id。
Future<void> showPlanChat(BuildContext context, {int? planId, String? planName}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    isDismissible: true,
    enableDrag: true,
    builder: (_) => _PlanChatSheet(planId: planId, planName: planName),
  );
}

class _PlanChatSheet extends ConsumerStatefulWidget {
  const _PlanChatSheet({this.planId, this.planName});
  final int? planId;
  final String? planName;

  @override
  ConsumerState<_PlanChatSheet> createState() => _PlanChatSheetState();
}

class _PlanChatSheetState extends ConsumerState<_PlanChatSheet> {
  final TextEditingController _inputCtrl = TextEditingController();
  final StringBuffer _aiText = StringBuffer();
  final List<String> _toolEvents = [];
  bool _busy = false;
  String? _errorText;
  int? _createdPlanId;
  StreamSubscription<AgentEvent>? _sub;

  @override
  void dispose() {
    _sub?.cancel();
    _inputCtrl.dispose();
    super.dispose();
  }

  Future<void> _runAgent() async {
    if (_busy) return;
    final userText = _inputCtrl.text.trim();
    if (userText.isEmpty) return;
    setState(() {
      _busy = true;
      _errorText = null;
      _aiText.clear();
      _toolEvents.clear();
    });

    final messages = <ChatMessage>[ChatMessage(role: 'user', content: userText)];
    try {
      final session = ref.read(planSessionProvider);
      final stream = await session.run(messages, planId: widget.planId, today: DateTime.now());
      if (!mounted) return;
      _sub = stream.listen(
        (event) {
          if (!mounted) return;
          setState(() {
            switch (event) {
              case TextDeltaEvent(:final delta):
                _aiText.write(delta);
                break;
              case ToolCallStartEvent(:final name):
                _toolEvents.add('→ 调用工具：$name');
                break;
              case ToolCallEndEvent(:final name, :final result):
                _toolEvents.add('← $name：$result');
                // 新建模式下捕获 create_plan 返回的 plan_id
                if (widget.planId == null && name == 'create_plan') {
                  final m = RegExp(r'"plan_id":\s*(\d+)').firstMatch(result);
                  if (m != null) _createdPlanId = int.tryParse(m.group(1)!);
                }
                break;
              case ToolProgressEvent(:final progress):
                _toolEvents.add('· $progress');
                break;
              case CompactionEvent():
                _toolEvents.add('· 上下文已压缩');
                break;
              case RetryEvent(:final attempt):
                _toolEvents.add('· 重试第 $attempt 次');
                break;
              case AgentStartedEvent():
              case AgentDoneEvent():
                _busy = false;
                break;
              case AgentErrorEvent(:final message):
                _errorText = message;
                _busy = false;
                break;
            }
          });
        },
        onError: (e) {
          if (!mounted) return;
          setState(() { _errorText = '$e'; _busy = false; });
        },
        onDone: () {
          if (!mounted) return;
          setState(() => _busy = false);
          // 新建成功 → 跳详情页
          if (_createdPlanId != null) {
            Navigator.of(context).pop();
            context.go('/plan/$_createdPlanId');
          }
        },
      );
    } catch (e) {
      if (!mounted) return;
      setState(() { _errorText = '$e'; _busy = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    return Padding(
      padding: EdgeInsets.only(left: 16, right: 16, top: 12, bottom: mq.viewInsets.bottom + 16),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(width: 40, height: 4, margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(color: Colors.grey.shade400, borderRadius: BorderRadius.circular(2))),
            ),
            Text(
              widget.planName != null ? '正在调整：${widget.planName}' : '新建学习计划',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              widget.planId == null
                  ? '告诉我考试日期、内容、目标、每日时长和当前水平，我帮你拆计划。'
                  : '说说你想怎么调整，比如"把第 3 个节点提前一周"。',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _inputCtrl,
              enabled: !_busy,
              decoration: const InputDecoration(
                labelText: '消息',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              maxLines: 2,
              onSubmitted: (_) => _runAgent(),
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: _busy ? null : _runAgent,
              child: Text(_busy ? '思考中...' : '发送'),
            ),
            const SizedBox(height: 16),
            if (_errorText != null)
              Container(
                padding: const EdgeInsets.all(8),
                color: Colors.red.shade50,
                child: Text(_errorText!, style: TextStyle(color: Colors.red.shade900, fontSize: 12)),
              ),
            if (_toolEvents.isNotEmpty) ...[
              const Text('工具调用', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
              const SizedBox(height: 4),
              ..._toolEvents.map((e) => Text(e, style: const TextStyle(fontSize: 12))),
              const SizedBox(height: 12),
            ],
            if (_aiText.isNotEmpty) ...[
              const Text('AI 回复', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
              const SizedBox(height: 4),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: Colors.grey.shade100, borderRadius: BorderRadius.circular(6)),
                child: SelectableText(_aiText.toString()),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `cd study_buddy && dart analyze lib/features/plan/plan_chat_sheet.dart`
Expected: No issues.

- [ ] **Step 3: Commit**

```bash
git add study_buddy/lib/features/plan/plan_chat_sheet.dart
git commit -m "feat(plan): PlanChatSheet — AI 对话调整(新建/调整双模式)"
```

---

## Task 10: 计划详情页

**Files:**
- Create: `study_buddy/lib/features/plan/plan_detail_page.dart`
- Modify: `study_buddy/lib/router.dart`

**Interfaces:**
- Consumes: Task 6 `planDetailProvider` + Task 7 `ProgressChart` + Task 8 `showAssessmentEntry` + Task 9 `showPlanChat`。
- Produces: `PlanDetailPage({required int planId})` widget。三段式：提醒横幅（距上次测评>14天显示）+ 曲线 + 里程碑时间线（点勾切换 status）。AppBar 💬 进 AI 对话。路由 `/plan/:id`。

- [ ] **Step 1: Create the detail page**

Create `study_buddy/lib/features/plan/plan_detail_page.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/plan_provider.dart';
import 'assessment_entry_sheet.dart';
import 'plan_chat_sheet.dart';
import 'progress_chart.dart';

class PlanDetailPage extends ConsumerWidget {
  const PlanDetailPage({super.key, required this.planId});
  final int planId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detailAsync = ref.watch(planDetailProvider(planId));
    return Scaffold(
      appBar: AppBar(
        title: detailAsync.maybeWhen(data: (d) => Text(d.plan.name), orElse: () => const Text('计划详情')),
        actions: [
          IconButton(
            icon: const Icon(Icons.chat_bubble_outline),
            tooltip: '和 AI 调整',
            onPressed: () async {
              final name = detailAsync.maybeWhen(data: (d) => d.plan.name, orElse: () => null);
              await showPlanChat(context, planId: planId, planName: name);
              // 对话可能改了计划，刷新
              ref.invalidate(planDetailProvider(planId));
            },
          ),
        ],
      ),
      body: detailAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('加载失败: $e')),
        data: (detail) {
          final plan = detail.plan;
          final milestones = detail.milestones;
          final assessments = detail.assessments;
          final doneCount = milestones.where((m) => m.status == 'done').length;

          // 提醒横幅：距上次测评>14天
          final lastA = assessments.isNotEmpty ? assessments.last : null;
          final showReminder = lastA == null
              ? false
              : DateTime.now().difference(lastA.assessedAt).inDays > 14;

          // 目标线分数：从 target 抽数字
          final targetScore = _extractScore(plan.target);

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (showReminder)
                Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: Colors.orange.shade50, borderRadius: BorderRadius.circular(8)),
                  child: Row(
                    children: [
                      Icon(Icons.warning_amber_rounded, color: Colors.orange.shade800),
                      const SizedBox(width: 8),
                      Expanded(child: Text('距上次测评已 ${DateTime.now().difference(lastA!.assessedAt).inDays} 天，建议做一次测评。', style: TextStyle(color: Colors.orange.shade900))),
                    ],
                  ),
                ),
              // 曲线
              const Text('进步曲线', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              ProgressChart(assessments: assessments, targetScore: targetScore),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('记录测评'),
                  onPressed: () async {
                    final ok = await showAssessmentEntry(context, planId);
                    if (ok == true) ref.invalidate(planDetailProvider(planId));
                  },
                ),
              ),
              const SizedBox(height: 16),
              // 里程碑时间线
              Text('里程碑（$doneCount/${milestones.length}）', style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              ...milestones.map((m) {
                final isDone = m.status == 'done';
                final daysTo = m.targetDate.difference(DateTime.now()).inDays;
                final near = daysTo.abs() <= 3;
                return Card(
                  child: ListTile(
                    leading: IconButton(
                      icon: Icon(isDone ? Icons.check_circle : Icons.radio_button_unchecked,
                          color: isDone ? Colors.green : (near ? Colors.orange : Colors.grey)),
                      onPressed: () async {
                        final repo = await ref.read(planRepositoryAsyncProvider.future);
                        await repo.updateMilestone(m.id!, status: isDone ? 'pending' : 'done');
                        ref.invalidate(planDetailProvider(planId));
                      },
                    ),
                    title: Text(
                      '${m.targetDate.month}/${m.targetDate.day} ${m.title}',
                      style: TextStyle(decoration: isDone ? TextDecoration.lineThrough : null, color: isDone ? Colors.grey : null),
                    ),
                    subtitle: Text(m.description, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
                    trailing: near && !isDone
                        ? Text(daysTo == 0 ? '今天' : '${daysTo}天', style: TextStyle(color: Colors.orange.shade800, fontSize: 12))
                        : null,
                  ),
                );
              }),
            ],
          );
        },
      ),
    );
  }

  int? _extractScore(String target) {
    final m = RegExp(r'\d+').firstMatch(target);
    return m == null ? null : int.tryParse(m.group(0)!);
  }
}
```

- [ ] **Step 2: Add the route**

Modify `study_buddy/lib/router.dart` — 在 `PermissionGuidePage` 路由后追加：

```dart
import 'features/plan/plan_detail_page.dart';
```
（加到文件顶部 import 区）

在 routes 列表末尾追加：
```dart
      GoRoute(
        path: '/plan/:id',
        builder: (context, state) => PlanDetailPage(
          planId: int.parse(state.pathParameters['id']!),
        ),
      ),
```

- [ ] **Step 3: Verify it compiles**

Run: `cd study_buddy && dart analyze lib/features/plan/plan_detail_page.dart lib/router.dart`
Expected: No issues.

- [ ] **Step 4: Commit**

```bash
git add study_buddy/lib/features/plan/plan_detail_page.dart study_buddy/lib/router.dart
git commit -m "feat(plan): PlanDetailPage — 提醒横幅+曲线+里程碑时间线 + /plan/:id 路由"
```

---

## Task 11: 首页改造（计划列表入口）

**Files:**
- Modify: `study_buddy/lib/features/home/home_page.dart`

**Interfaces:**
- Consumes: Task 6 `planListProvider` + Task 9 `showPlanChat` + 既有 `screenshotProvider`。
- Produces: 改造后的 `HomePage` — 主体渲染计划列表（卡片：名称 + 考试日期 + 目标 + 进度 + 最近分），点进详情；底部 `+ 新建计划` 按钮开 `showPlanChat`（空 planId）；悬浮窗状态降到底部小字。

- [ ] **Step 1: Rewrite home_page.dart**

Replace `study_buddy/lib/features/home/home_page.dart` body. Keep `_checkPermission` / `_consumePendingScreenshot` / `_checkForUpdate` logic, but change `build` to render plan list. Full file:

```dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:study_engine/study_engine.dart';

import '../../core/providers/app_update_provider.dart';
import '../../core/providers/database_provider.dart';
import '../../core/providers/plan_provider.dart';
import '../../core/providers/screenshot_provider.dart';
import '../../core/update/app_update_service.dart';
import '../../core/update/models/update_check_result.dart';
import '../../core/update/ui/app_update_dialog.dart';
import '../../features/external_qbank/ai_panel_sheet.dart';
import '../../features/plan/plan_chat_sheet.dart';
import '../../main.dart' show PendingScreenshotStore;

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});
  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  bool? _overlayGranted;

  @override
  void initState() {
    super.initState();
    _checkPermission();
    _consumePendingScreenshot();
  }

  Future<void> _checkPermission() async {
    final granted = await ref.read(screenshotProvider).checkOverlayPermission();
    if (mounted) setState(() => _overlayGranted = granted);
    if (granted) {
      await ref.read(screenshotProvider).showOverlay();
    }
  }

  Future<void> _consumePendingScreenshot() async {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final pending = PendingScreenshotStore.pending;
      if (pending != null) {
        PendingScreenshotStore.pending = null;
        if (mounted) await showAiPanel(context, screenshot: pending);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final dbAsync = ref.watch(databaseProvider);
    final plansAsync = ref.watch(planListProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Study Buddy')),
      body: dbAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('数据库初始化失败: $e')),
        data: (_) => plansAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('加载计划失败: $e')),
          data: (plans) => RefreshIndicator(
            onRefresh: () async => ref.invalidate(planListProvider),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text('我的学习计划', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                ...plans.map((p) => _PlanCard(plan: p, onTap: () => context.go('/plan/${p.id}'))),
                if (plans.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Center(child: Text('还没有计划，新建一个吧', style: TextStyle(color: Colors.grey.shade600))),
                  ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  icon: const Icon(Icons.add),
                  label: const Text('新建计划'),
                  onPressed: () async {
                    await showPlanChat(context);
                    ref.invalidate(planListProvider);
                  },
                ),
                const SizedBox(height: 24),
                // 悬浮窗状态降到底部次要区
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(_overlayGranted == true ? Icons.screenshot_monitor : Icons.screenshot_monitor_outlined,
                        size: 14, color: Colors.grey.shade500),
                    const SizedBox(width: 4),
                    Text(
                      _overlayGranted == null ? '检查悬浮窗权限中...' : _overlayGranted == true ? '悬浮窗已开启' : '悬浮窗未开启',
                      style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                    ),
                  ],
                ),
                if (_overlayGranted == false)
                  TextButton(
                    onPressed: () => context.go('/permission-guide'),
                    child: const Text('去开启悬浮窗权限', style: TextStyle(fontSize: 11)),
                  ),
                if (Platform.isAndroid) ...[
                  const SizedBox(height: 8),
                  TextButton.icon(
                    icon: const Icon(Icons.system_update_alt, size: 14),
                    label: const Text('检查更新', style: TextStyle(fontSize: 11)),
                    onPressed: () => _checkForUpdate(context, ref),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _checkForUpdate(BuildContext context, WidgetRef ref) async {
    final service = ref.read(appUpdateServiceProvider);
    final preview = await AppUpdateService.isPreviewChannelEnabled();
    final result = await service.checkForUpdateDetailed(forceCheck: true, includePrerelease: preview);
    if (!context.mounted) return;
    switch (result) {
      case AppUpdateAvailable(:final version):
        await showAppUpdateDialog(context, version: version, updateService: service);
      case AppUpdateUpToDate():
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已是最新版本')));
      case AppUpdateCheckFailed(:final reason):
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('检查失败：$reason')));
    }
  }
}

class _PlanCard extends ConsumerWidget {
  const _PlanCard({required this.plan, required this.onTap});
  final Plan plan;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = plan;
    return Card(
      child: ListTile(
        title: Text(p.name, style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text('考试 ${p.examDate.year}/${p.examDate.month}/${p.examDate.day} · 目标 ${p.target}'),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}
```

> 注意：`_consumePendingScreenshot` 原来调用了 `showAiPanel(context, screenshot: pending)`。改造首页时该导入（`ai_panel_sheet.dart`）若不再用，保留导入会导致 unused lint；若保留调用则维持原逻辑。实现时优先保持原 `showAiPanel` 调用不破坏截图冷启动降级——即把 `_consumePendingScreenshot` 恢复成调用 `showAiPanel`，并保留对应 import。验证以 Step 2 的 `dart analyze` 为准：若有 unused import 删掉，若缺 import 补上。

- [ ] **Step 2: Verify it compiles + fix imports**

Run: `cd study_buddy && dart analyze lib/features/home/home_page.dart`
Expected: No issues. 顶部 import 已包含 `ai_panel_sheet.dart`（用于 `_consumePendingScreenshot` 的 `showAiPanel` 调用）、`plan_provider.dart`、`plan_chat_sheet.dart`，以及 `Plan` 强类型所需的 `study_engine.dart`；若 dart analyze 仍报 unused_import，按需删 import 不重复项即可。

- [ ] **Step 3: Run app to smoke-test**

Run: `cd study_buddy && flutter run`（或 `flutter run -d windows`）
手动验证：
- 首页显示"我的学习计划"标题 + 空态"还没有计划" + "新建计划"按钮。
- 点"新建计划"弹出 AI 对话弹窗（不实际发消息也行，验证 UI 出现）。
- 悬浮窗状态在底部小字显示。
- 无崩溃。

- [ ] **Step 4: Commit**

```bash
git add study_buddy/lib/features/home/home_page.dart
git commit -m "feat(home): 首页改造为计划列表入口(悬浮窗状态降级)"
```

---

## Task 12: 全量验证 + 手工验收

**Files:**
- 无新文件，全量回归。

- [ ] **Step 1: Run full engine test suite**

Run: `cd packages/study_engine && dart test`
Expected: 所有测试 PASS（含既有 + 新增 plan 相关 4 个测试文件）。

- [ ] **Step 2: Run engine analyze**

Run: `cd packages/study_engine && dart analyze`
Expected: No issues.

- [ ] **Step 3: Run app analyze**

Run: `cd study_buddy && dart analyze`
Expected: No issues.

- [ ] **Step 4: Run app and full manual acceptance**

Run: `cd study_buddy && flutter run`（或 `-d windows`）

手工验收清单（需先在 DB 配好 `is_default=1` 的 LlmConfig，否则计划场景抛"未配置默认 LLM"）：
- [ ] 首页空态显示，点"新建计划"弹 AI 对话。
- [ ] 输入"我要考研，12月21日考试，考408，目标380，每天3小时，现在估300分"，AI 应调 create_plan + 多个 add_milestone。
- [ ] create_plan 成功后自动跳转 `/plan/<id>` 详情页。
- [ ] 详情页显示曲线（1 个点 300 + 目标虚线 380）、里程碑列表、无提醒横幅（刚测评）。
- [ ] 点"记录测评"弹窗，输入 310 + 备注，保存后曲线变 2 个点。
- [ ] 点里程碑勾框，status 切换为 done（灰色打勾）。
- [ ] 点 AppBar 💬，弹 AI 对话，输入"把第 1 个节点延后一周"，AI 应调 update_milestone。
- [ ] 返回首页，列表显示该计划卡片。
- [ ] 悬浮窗截图功能仍正常（未破坏既有功能）。

- [ ] **Step 5: Commit any fixups**

若无 fixup 跳过。若有：
```bash
git add -A
git commit -m "test: 全量验证通过"
```

- [ ] **Step 6: Update memory**

完成后在记忆里更新一条 progress 记录（参考既有 `study-buddy-foundation-done.md` 风格），记录学习计划功能已落地 + 技术债清单（系统通知、估分、撤销历史、跨计划冲突检测）。
