# 专注时钟与学习日报 — 设计稿

- **日期**：2026-08-10
- **项目**：study_buddy + study_engine
- **阶段**：第三阶段子能力（独立交付，依附于现有悬浮球 AI 流程）
- **状态**：已确认，待实施计划
- **前置依赖**：study_engine v2 数据库地基、悬浮球截图 AI 流程（`ScreenshotProvider` / `AgentSession` / `StudyScenario`）、Android 原生前台服务基建（`OverlayService` 模式）

---

## 1. 背景与目标

### 现状痛点
- 当前 app 唯一的 AI 入口是「悬浮球截图 → 抽屉分析」，用户随时可以学新知识点，但**学了多少、学了多久完全无记录**。
- 全树 grep `Timer / Stopwatch / Duration` 零命中，没有任何计时/会话/日报机制。
- `mastery_log` 只记知识点掌握状态变更，不记学习过程；`topic` 表无任何学习时长字段。

### 本 spec 做什么
新增「专注时钟」功能：用户手动开始一次专注会话，期间通过悬浮球截图学到的知识点自动关联到该会话；会话进行中通知栏常驻实时计时；结束后该会话进入当天的学习日报。日报页展示当天总专注用时、各会话起止时间范围、以及当天接触的知识点列表。

### 1.1 MVP 交付目标
1. 首页可进入「专注」页，点「开始专注」启动计时，通知栏出现常驻计时通知（每秒刷新 + 「停止」按钮）。
2. 专注会话进行中，AI 通过 `save_topic` / `update_topic` 处理的知识点自动关联到当前会话。
3. 点「结束专注」或通知栏「停止」均可结束会话并落库（`focus_session` + `focus_session_topic`）。
4. 首页可进入「学习日报」页，展示选定日期（默认今天）的总专注用时、各会话时间范围、当天学过的知识点列表，支持切换历史日期。

### 1.2 关键约束

| 约束 | 解读 |
|------|------|
| 计时只开始/结束，不暂停 | 状态机只有 `idle → running → ended`，无 `paused`。简化计时逻辑与 UI。 |
| 通知栏实时计时 + 停止按钮 | 必须用 Android 前台服务（普通通知进程被杀即中断），与现有 `OverlayService` 同构。 |
| 日报不拆时长到知识点 | 日报只展示「总用时 + 各会话时间范围」+「当天接触的知识点列表」，知识点不挂时长。 |
| 截图分析不入报 | 撤回「两者结合」。只有「专注会话进行中」的 AI 工具调用才关联；非专注期的截图分析不产生任何记录。 |
| engine 改动向后兼容 | 新增表（migration v3）、新增可选回调，不改现有签名、不破坏现有 22 个测试。 |
| 跨进程状态一致性 | Flutter 是计时主源（Stopwatch），原生通知栏是镜像展示。停止的最终落库由 Flutter 统一完成，避免双写。 |

---

## 2. 设计输入（已确认决策）

| 维度 | 决策 | 依据 |
|------|------|------|
| 计时触发 | 手动开始/结束 | 用户明确选择，符合「专注」语义 |
| 中途暂停 | 不支持 | 用户明确选择，状态机简化 |
| 通知栏 | 前台服务实时计时 + 停止按钮 | 用户明确要求从通知栏可停止 |
| 日报形式 | app 内页面 | 用户明确排除分享图片、LLM 小结 |
| 日报内容 | 总用时 + 会话时间范围 + 知识点列表 | 用户明确「不拆时长到知识点，只要总用时和时间范围」 |
| 知识点归属 | 仅专注会话中的 AI 工具调用关联 | 用户明确「截图分析不统计」 |
| 历史回看 | 支持，按日期查询 | 数据按日期落库，日报页提供日期切换 |

---

## 3. 顶层架构

```
┌──────────────────────────────────────────────────────────────────┐
│ study_buddy (Flutter app)                                         │
│                                                                   │
│  features/focus/focus_page.dart        features/focus/daily_report_page.dart │
│   开始/结束按钮 + 计时显示              总用时 + 会话列表 + 知识点列表          │
│        │                                       ▲                  │
│        ▼                                       │                  │
│  core/providers/focus_session_provider.dart    │                  │
│   StateNotifier<FocusSessionState>             │                  │
│   - Stopwatch 计时（主源）                      │                  │
│   - Stream.periodic(1s) 驱动 UI 刷新           │                  │
│   - 持有 currentSessionId（活跃会话 id）        │                  │
│        │  MethodChannel "study_buddy/focus"    │                  │
│        ▼                                       │                  │
│  [原生] FocusTimerService（前台服务）            │                  │
│   - startForeground 常驻通知                    │                  │
│   - 每秒刷新通知正文（已计时 mm:ss）             │                  │
│   - 通知「停止」Action → 回调 Flutter            │                  │
│        │                                       │                  │
│        ▼  onTopicTouched(topicId) 注入          │                  │
│  core/providers/agent_session_provider.dart    │                  │
│   AgentSession.run() 构造 StudyScenario 时     │                  │
│   注入 onTopicTouched（写 focus_session_topic）│                  │
└──────────────┬──────────────────────────────────┴──────────────────┘
               │
               ▼
┌──────────────────────────────────────────────────────────────────┐
│ study_engine (纯 Dart 包)                                         │
│  db/database_migrations.dart: _v3 新增 focus_session / focus_session_topic │
│  models/models.dart: FocusSession / FocusSessionTopic            │
│  repos/focus_session_repository.dart（新增）                       │
│  agent/scenarios/study_scenario.dart: 加可选 onTopicTouched 回调   │
│  aggregations/daily_report.dart（新增，按日期聚合的纯函数）          │
└──────────────────────────────────────────────────────────────────┘
```

### 关键设计点
- **三层职责分离**：Flutter 管计时状态与 UI，原生管通知栏展示，engine 管数据持久化与聚合。每层可独立测试。
- **计时主源唯一**：Flutter `Stopwatch` 驱动 UI 实时刷新，但落库的 `duration_ms` 以「Stopwatch 停止时刻的读数」为准；异常路径（进程被杀的孤儿会话）以 DB 的 `started_at` 与恢复时刻差值兜底。停止的落库由 Flutter 统一完成，避免双写不一致。
- **engine 改动向后兼容**：新增 migration v3、新增可选回调参数 `onTopicTouched`（默认 no-op），现有调用方零改动。
- **知识点关联通过回调注入**：`StudyScenario` 增加可选 `onTopicTouched` 回调，在 `save_topic` / `update_topic` 执行成功后触发。app 层注入的实现：若当前有活跃会话则写 `focus_session_topic`。engine 不感知「会话」概念，保持职责单一。

### 3.1 数据流（时序）

**开始专注**
```
用户点「开始」
  → FocusSessionNotifier.start()
  → engine: FocusSessionRepository.insert(开始时间) → 得 sessionId
  → 原生: FocusTimerService.start(sessionId) → 前台通知常驻
  → Stopwatch.start() + Stream.periodic(1s) → UI 每秒刷新
```

**专注中学习知识点**
```
用户截图 → AI 抽屉 → AgentSession.run()
  → StudyScenario.executeTool('save_topic', ...)
  → topics.insert(...) 成功 → onTopicTouched(topicId)
  → app 注入实现: 若 currentSessionId != null
    → FocusSessionRepository.linkTopic(sessionId, topicId)
```

**结束专注（app 内或通知栏）**
```
通知栏「停止」→ 原生回调 → FocusTimerService → MethodChannel 回 Flutter
  或 app 内点「结束」
  → FocusSessionNotifier.stop()
  → Stopwatch.stop() → 计算 duration
  → engine: FocusSessionRepository.endSession(sessionId, endedAt, duration)
  → 原生: FocusTimerService.stop() → 取消前台通知
  → 清空 currentSessionId
```

**查看日报**
```
日报页选日期
  → DailyReportAggregator.build(date)
  → FocusSessionRepository.findByDate(date) → 当天所有会话
  → 各会话的 focus_session_topic → 关联 topic 详情
  → 聚合: 总用时 = sum(duration); 会话列表 = [{起止, duration}]; 知识点列表 = 去重 topic
```

### 3.2 跨进程状态一致性

**问题**：Flutter 与原生各有计时状态，停止可能来自任一侧。

**方案**：Flutter 是唯一主源。
- 通知栏「停止」→ 原生仅发 MethodChannel 回调 `onStop` → Flutter 收到后执行 `stop()` 全流程（含通知原生取消通知）。
- app 内「结束」→ Flutter 执行 `stop()` → 通知原生取消通知。
- 原生不独立落库、不独立计算 duration。原生只管「展示」与「转发停止意图」。
- 若 Flutter 进程被杀（极端情况）：原生通知仍在，但停止回调无法到达 Flutter。此时原生通知在下次 app 启动时由 Flutter 主动查询 `isRunning` 并清理（见错误处理 §5）。

---

## 4. 组件清单

### 新增

#### study_engine 侧

**`packages/study_engine/lib/src/models/models.dart`（追加）**

```dart
/// 一次专注学习会话。
class FocusSession {
  final int? id;
  final DateTime startedAt;
  final DateTime? endedAt;    // null = 进行中
  final int? durationMs;      // null = 进行中；ended 后填入
  const FocusSession({this.id, required this.startedAt, this.endedAt, this.durationMs});

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

/// 专注会话与知识点的关联（多对多，不记时长）。
class FocusSessionTopic {
  final int? id;
  final int sessionId;
  final int topicId;
  final DateTime linkedAt;
  const FocusSessionTopic({this.id, required this.sessionId, required this.topicId, required this.linkedAt});

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

**`packages/study_engine/lib/src/db/database_migrations.dart`（修改）**

```dart
const int kCurrentDbVersion = 3;  // 2 → 3

// migrateDatabase switch 增加：
case 3:
  _v3(batch);
  break;

/// v3：专注时钟。新增 focus_session（会话）与 focus_session_topic（会话-知识点关联）。
/// 非破坏性：仅加表，不动现有 v2 表。
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

**`packages/study_engine/lib/src/repos/focus_session_repository.dart`（新增）**

```dart
import '../db/database.dart';
import '../models/models.dart';

class FocusSessionRepository {
  final StudyDatabase _db;
  FocusSessionRepository(this._db);

  /// 开始一次会话：插入 started_at，返回 id。
  Future<int> start(DateTime startedAt) {
    return _db.db.insert('focus_session', FocusSession(startedAt: startedAt).toMap());
  }

  /// 结束会话：写入 ended_at 与 duration_ms。
  Future<void> end(int sessionId, DateTime endedAt, int durationMs) {
    return _db.db.update(
      'focus_session',
      {'ended_at': endedAt.millisecondsSinceEpoch, 'duration_ms': durationMs},
      where: 'id = ?', whereArgs: [sessionId],
    );
  }

  /// 关联知识点到会话（UNIQUE 保证幂等，重复关联被忽略）。
  Future<void> linkTopic(int sessionId, int topicId) async {
    try {
      await _db.db.insert('focus_session_topic',
          FocusSessionTopic(sessionId: sessionId, topicId: topicId, linkedAt: DateTime.now()).toMap());
    } catch (e) {
      if (!e.toString().contains('UNIQUE constraint failed')) rethrow;
      // 幂等：已关联则忽略
    }
  }

  /// 查某日全部会话（按 started_at 升序）。dateLocal 为本地日期。
  Future<List<FocusSession>> findByDate(DateTime dateLocal) async {
    final start = DateTime(dateLocal.year, dateLocal.month, dateLocal.day).millisecondsSinceEpoch;
    final end = DateTime(dateLocal.year, dateLocal.month, dateLocal.day + 1).millisecondsSinceEpoch;
    final rows = await _db.db.query(
      'focus_session',
      where: 'started_at >= ? AND started_at < ?',
      whereArgs: [start, end],
      orderBy: 'started_at ASC',
    );
    return rows.map(FocusSession.fromMap).toList();
  }

  /// 查某会话关联的知识点 id 列表。
  Future<List<int>> topicIdsOf(int sessionId) async {
    final rows = await _db.db.query('focus_session_topic',
        where: 'session_id = ?', whereArgs: [sessionId], orderBy: 'linked_at ASC');
    return rows.map((r) => r['topic_id'] as int).toList();
  }
}
```

**`packages/study_engine/lib/src/aggregations/daily_report.dart`（新增）**

```dart
import '../models/models.dart';
import '../repos/focus_session_repository.dart';
import '../repos/topic_repository.dart';

/// 日报中一个会话的展示项。
class DailyReportSession {
  final FocusSession session;
  final List<Topic> topics;  // 该会话关联的知识点详情
  const DailyReportSession(this.session, this.topics);
}

/// 日报聚合结果。
class DailyReport {
  final DateTime date;
  final List<DailyReportSession> sessions;
  const DailyReport(this.date, this.sessions);

  /// 当天总专注用时（毫秒）。
  int get totalDurationMs =>
      sessions.fold(0, (sum, s) => sum + (s.session.durationMs ?? 0));

  /// 当天接触的全部知识点（去重，保持首次出现顺序）。
  List<Topic> get uniqueTopics {
    final seen = <int>{};
    final result = <Topic>[];
    for (final s in sessions) {
      for (final t in s.topics) {
        if (seen.add(t.id!)) result.add(t);
      }
    }
    return result;
  }
}

/// 纯函数：按日期聚合日报。无副作用，易测试。
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

#### study_buddy 侧

**`study_buddy/lib/core/providers/focus_session_provider.dart`（新增）**

```dart
class FocusSessionState {
  final int? sessionId;       // null = idle；非 null = running
  final DateTime? startedAt;
  final Duration elapsed;     // 已计时
  final bool running;
  const FocusSessionState({
    this.sessionId, this.startedAt, this.elapsed = Duration.zero,
    this.running = false,
  });
  static const idle = FocusSessionState();
}

class FocusSessionNotifier extends StateNotifier<FocusSessionState> {
  FocusSessionNotifier(this._ref) : super(FocusSessionState.idle);
  final Ref _ref;
  Stopwatch? _stopwatch;
  StreamSubscription<Duration>? _tick;

  Future<void> start() async { /* 见 §3.1 */ }
  Future<void> stop() async { /* 见 §3.1，app 内与通知栏统一入口 */ }
  void dispose() { _tick?.cancel(); super.dispose(); }
}
```

**`study_buddy/lib/core/providers/focus_timer_bridge.dart`（新增）** — 原生通知栏桥接

```dart
class FocusTimerBridge {
  static const _channel = MethodChannel('study_buddy/focus');
  // start(sessionId) / stop() / isRunning()
  // 设置回调 handler 接收原生「停止」通知
}
```

**`study_buddy/lib/features/focus/focus_page.dart`（新增）** — 专注页

**`study_buddy/lib/features/focus/daily_report_page.dart`（新增）** — 日报页

**`study_buddy/lib/router.dart`（修改）** — 加 `/focus`、`/daily-report` 路由

**`study_buddy/lib/features/home/home_page.dart`（修改）** — 加「开始专注」「学习日报」入口按钮

#### Android 原生侧

**`FocusTimerService.kt`（新增）** — 前台服务，每秒刷新通知 + 停止 Action

**`FocusTimerPlugin.kt`（新增）** — MethodChannel `study_buddy/focus` 桥接（注册于 MainActivity）

**`MainActivity.kt`（修改）** — 注册 `FocusTimerPlugin`

**`AndroidManifest.xml`（修改）** — 声明 `FocusTimerService` + `POST_NOTIFICATIONS` 权限

### 修改

| 文件 | 改动 |
|------|------|
| `study_engine/lib/src/db/database_migrations.dart` | `kCurrentDbVersion` 2→3，加 `_v3` |
| `study_engine/lib/src/agent/scenarios/study_scenario.dart` | 加可选 `onTopicTouched` 回调字段，在 `_saveTopic`/`_updateTopic` 成功后触发 |
| `study_engine/lib/study_engine.dart`（barrel） | 导出 `FocusSessionRepository`、`FocusSession`、`FocusSessionTopic`、`buildDailyReport`、`DailyReport` 等 |
| `study_buddy/lib/core/providers/agent_session_provider.dart` | 构造 `StudyScenario` 时注入 `onTopicTouched`：从 `FocusSessionNotifier` 读当前活跃 sessionId（通过 `ref.read(focusSessionProvider).sessionId`），非 null 时调 `FocusSessionRepository.linkTopic` |
| `study_buddy/lib/router.dart` | 加 `/focus`、`/daily-report` 路由 |
| `study_buddy/lib/features/home/home_page.dart` | 加入口按钮 |
| `study_buddy/android/.../MainActivity.kt` | 注册 `FocusTimerPlugin` |
| `study_buddy/android/.../AndroidManifest.xml` | 声明 `FocusTimerService` + `POST_NOTIFICATIONS` 权限 |

### 不改动

- `agent_loop.dart` / `agent_event.dart` / `agent_tools.dart` — Agent 循环与工具 schema 不变。
- `topic_repository.dart` / `category_repository.dart` / `mastery_repository.dart` — 现有 Repository 不动。
- `OverlayService` / `ScreenCaptureService` 等悬浮球原生模块 — 与专注时钟正交。
- `chat_session_provider.dart` / `ai_panel_sheet.dart` — AI 抽屉逻辑不变（专注关联在更底层的 `agent_session_provider` 注入）。

---

## 5. 错误处理与边界

| 场景 | 处理 | 状态影响 |
|------|------|----------|
| 开始专注时 DB 写入失败 | `start()` 抛错，UI 提示「启动失败」，不进 running 态 | 保持 idle |
| 通知栏启动失败（Android 13+ 未授权 POST_NOTIFICATIONS） | 前台服务仍启动（通知可能不可见），计时正常进行；UI 提示「通知权限未开启，无法在通知栏查看」 | 进入 running，通知栏降级 |
| 专注中 app 被杀（进程销毁） | 原生 `FocusTimerService` 仍存活（前台服务保活）；DB 中会话 `ended_at` 为 null。下次 app 启动检测到孤儿会话 | 见下方「孤儿会话清理」 |
| 通知栏「停止」时 Flutter 未响应（极端） | 原生重试回调一次；仍未响应则原生自取消通知，标记待清理 | 下次启动清理孤儿 |
| 专注中 AI 工具调用失败 | `onTopicTouched` 不触发（只在 insert/update 成功后调），不影响会话 | 会话继续 |
| `linkTopic` 写入失败（非 UNIQUE） | 记日志、吞错（不阻断 AI 主流程） | 知识点未关联但不影响学习 |
| 日报查询某日无会话 | 返回空 `DailyReport`，UI 展示「这天没有专注记录」 | 正常空态 |
| 用户在专注中再次点「开始」 | `start()` 检测 `state.running` 直接 return | 维持当前会话 |
| 跨午夜会话 | 按 `started_at` 日期归入当天；duration 跨天不拆分 | 会话完整归到开始日 |

### 孤儿会话清理
app 启动时（`FocusSessionNotifier` 初始化或首页 `initState`）：
1. 调 `FocusTimerBridge.isRunning()` 查原生是否仍有前台服务。
2. 查 DB 是否有 `ended_at IS NULL` 的会话。
3. 若原生未运行但 DB 有未结束会话 → 视为崩溃残留，以「现在」为 endedAt、duration 取 `now - startedAt`（尽力而为）补结束。
4. 若原生仍在运行但 Flutter 状态 idle → 恢复 running 态（Stopwatch 从 `startedAt` 重算 elapsed），重新接管。

### 失败回滚策略
- `start()` 失败：DB 未写入则无副作用；若 DB 写入成功但原生启动失败 → 回滚删除该 session 记录，回到 idle。
- `stop()` 失败：原生通知取消失败不阻断（计时已停、DB 已结束）；残留通知在下次启动清理。

---

## 6. 测试策略

| 层 | 策略 | 数量预估 |
|----|------|----------|
| engine 模型 | `FocusSession`/`FocusSessionTopic` 的 `toMap`/`fromMap` 往返 | 2 |
| engine 迁移 | v3 建表、从 v2 升级到 v3 表结构正确、索引存在 | 2 |
| engine Repository | `start`/`end`/`linkTopic`(含 UNIQUE 幂等)/`findByDate`(含跨日边界)/`topicIdsOf` | 6 |
| engine 聚合 | `buildDailyReport` 空日、单会话、多会话去重、跨午夜 | 4 |
| engine StudyScenario | `onTopicTouched` 回调在 save/update 成功后触发、未设置回调时 no-op | 3 |
| engine 回归 | 现有 22 个测试全绿（兼容性自检） | 0 新增 |
| app provider | `FocusSessionNotifier` idle→running→ended 状态流转、重复 start 拦截、stop 后 sessionId 清空 | 4 |
| app 桥接 | `FocusTimerBridge` 方法调用契约（用 mock MethodChannel） | 3 |
| app widget | 专注页开始/结束按钮、计时显示；日报页空态、有数据态、日期切换 | 4 |
| **不写** | 原生 Kotlin 单测（前台服务依赖 Android 运行时，靠手测验证） | — |

engine 测试沿用 `sqflite_common_ffi` + `inMemoryDatabasePath` + `setUp/tearDown` 模式（见现有 `repos_test.dart`）。app 测试沿用 `ProviderContainer` + `overrideWith` 注入 fake 模式（见 `ai_panel_sheet_test.dart`）。

---

## 7. 范围控制（MVP 不做）

- ❌ 暂停/继续（状态机只有 idle/running/ended）
- ❌ 时长拆分到每个知识点
- ❌ 截图分析（非专注期）入报
- ❌ 日报分享图片 / 导出
- ❌ LLM 生成日报文字小结
- ❌ 专注期间屏幕常亮（wakelock）
- ❌ 专注模式全屏 / 防沉迷锁定
- ❌ 日报统计图表（周/月趋势）
- ❌ 学习目标 / 每日目标时长提醒
- ❌ iOS 支持（前台服务为 Android 概念，iOS 用不同机制，MVP 仅 Android）

---

## 8. 风险与缓解

| 风险 | 缓解 |
|------|------|
| Android 13+ 通知权限需运行时申请 | `FocusTimerBridge.start` 前检查并请求 `POST_NOTIFICATIONS`；被拒则降级（前台服务仍跑，通知不可见，app 内计时正常） |
| 前台服务每秒刷新通知可能耗电 | 用 `NotificationCompat.Builder` 复用同一 notification id 更新；仅更新 text 不重建。单次更新开销极小。 |
| Flutter 进程被杀导致计时中断 | 前台服务保活 + 启动时孤儿会话清理（§5）。duration 以 DB 的 `started_at`/`endedAt` 为准，Stopwatch 只是 UI 展示。 |
| `onTopicTouched` 注入破坏 StudyScenario 现有测试 | 回调设为可选（默认 no-op），现有测试不传该参数即可，零影响 |
| v3 迁移在生产设备失败 | 仅 `CREATE TABLE`，无 DROP/ALTER，风险极低；迁移失败时 `migrateDatabase` 已有异常传播机制 |
| 跨进程停止竞态（通知栏停 + app 内停几乎同时） | `stop()` 入口加 `if (!state.running) return` 守卫，先到者执行，后到者 no-op |

---

## 9. 硬约束自检

对照 §1.2 约束逐条自证：

1. **计时只开始/结束不暂停** — `FocusSessionState` 只有 `running` 布尔，无 `paused`；`FocusSessionNotifier` 无 `pause()` 方法。✅
2. **通知栏实时计时 + 停止按钮** — `FocusTimerService` 前台服务每秒刷新通知正文 + 「停止」Action 回调 Flutter。✅
3. **日报不拆时长到知识点** — `DailyReport` 只提供 `totalDurationMs` 与 `uniqueTopics`，`DailyReportSession` 挂 topics 但无 per-topic 时长。✅
4. **截图分析不入报** — `onTopicTouched` 仅在专注会话 `currentSessionId != null` 时写关联；非专注期回调为 no-op。✅
5. **engine 改动向后兼容** — `_v3` 只加表；`onTopicTouched` 可选参数默认 no-op；现有 22 测试不传该参数不受影响。✅
6. **跨进程状态一致性** — Flutter 主源，原生只展示与转发停止意图；停止统一走 `FocusSessionNotifier.stop()`。✅

---

## 下一步

spec 自审 → 用户审阅 → 调用 writing-plans 生成实施计划。
