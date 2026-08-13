# 知识卡【为什么？】等待态跳转 + 专属教学会话持久化 — 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让【为什么？】点击后先显示「正在思考怎么和你解释..」，AI 吐出首个文字 token 才跳转 AI 页（顶部常驻可折叠知识卡）；教学会话与主线完全隔离并持久化到知识点，再次点击直接复用上次记录（零 LLM 调用）、可继续追问。

**Architecture:** 新增独立 `topicTeachingProvider`（`ChatSessionNotifier` 实例，`_topicId` 为可变字段）承载教学会话；主线 `currentChatProvider` 不动。教学会话在 `chat_session` 表以可空 `topic_id` 列关联知识点（迁移 v11）。启动逻辑从 `AiChatPage` 移到详情页：点按钮 → `startTeaching(topicId)` 先查库恢复历史（有则直接 resolve），无历史才发开场并等首个 `TextDeltaEvent` 再 resolve → 详情页收到后 push `/ai`。`AiChatPage` 按 `initialTopicId` 编译期选定 provider，教学路径不 hydrate 主线。

**Tech Stack:** Flutter / Riverpod 3 (StateNotifierProvider) / go_router / study_engine（sqflite）。

**Spec:** `docs/superpowers/specs/2026-08-13-why-teaching-persist-design.md`

## Global Constraints

- 引擎层（`packages/study_engine`）不含 Flutter；App 层（`study_buddy/lib`）负责 provider/DB/UI。
- 数据库迁移 `kCurrentDbVersion` 从 10 → 11；新增迁移必须走 `_vN` + switch case，幂等。
- 教学与主线会话在 `chat_session` 表以可空 `topic_id` 区分：`NULL` = 主线，非空 = 教学。
- Riverpod 3「构建期禁止修改 provider」：教学启动只在用户点击或 `addPostFrameCallback` 触发。
- `AgentSession.run` 已支持 `topicId` 透传与 `topic_context` 注入，本计划**不改** `agent_session_provider.dart`。
- 测试沿用 fake `AgentSession`（`overrideWith((ref) => _FakeAgentSession(ref, events))`）与 sqflite_ffi 内存库（`databaseProvider.overrideWith((ref) async => sdb)`）模式。

---

### Task 1: 数据层 — 迁移 v11 + ChatRepository 扩展

**Files:**
- Modify: `packages/study_engine/lib/src/db/database_migrations.dart`
- Modify: `packages/study_engine/lib/src/repos/chat_repository.dart`
- Test: `packages/study_engine/test/chat_repository_test.dart`

**Interfaces:**
- Consumes: 无（基础层，无上游依赖）。
- Produces（后续任务依赖的签名）:
  - `Future<int> ChatRepository.createSession(String scenarioId, String title, {int? topicId})`
  - `Future<ChatSession?> ChatRepository.latestSession(String scenarioId, {bool mainlineOnly = true})`
  - `Future<ChatSession?> ChatRepository.findTeachingSession(int topicId)`
  - 迁移版本号 `kCurrentDbVersion = 11`

- [ ] **Step 1: 加迁移 v11（先改 schema，空库/升级均幂等）**

`database_migrations.dart`：
- 第 6 行：`const int kCurrentDbVersion = 10;` → `= 11;`
- switch 里 `case 10: _v10(batch); break;` 之后加：
```dart
case 11:
  _v11(batch);
  break;
```
- 文件末尾（`_v10` 之后）加：
```dart
/// v11：chat_session 增加可空 topic_id —— 知识点专属教学会话关联（NULL=主线普通会话）。
/// 仅增列，不改既有行；空库/升级均幂等。
void _v11(Batch batch) {
  batch.execute('ALTER TABLE chat_session ADD COLUMN topic_id INTEGER');
}
```

- [ ] **Step 2: 写 Repository 失败测试**

在 `packages/study_engine/test/chat_repository_test.dart` 末尾（main 内）新增：
```dart
test('教学会话:createSession 带 topicId,findTeachingSession 命中且 latestSession 主线过滤', () async {
  final sdb = await StudyDatabase.open(
      factory: databaseFactoryFfi, path: inMemoryDatabasePath);
  final repo = ChatRepository(sdb);
  // 一条主线（无 topicId）+ 一条教学（topicId=42）
  final mainlineId = await repo.createSession('study_plan', '主线');
  final teachingId =
      await repo.createSession('study_plan', '教学', topicId: 42);
  await repo.addMessage(mainlineId, const ChatMessage(role: 'user', content: '主线消息'));
  await repo.addMessage(teachingId, const ChatMessage(role: 'user', content: '教学消息'));

  // findTeachingSession 命中 topicId=42 的教学会话
  final found = await repo.findTeachingSession(42);
  expect(found, isNotNull);
  expect(found!.id, teachingId);
  // 未命中其他 topic
  expect(await repo.findTeachingSession(99), isNull);

  // latestSession 默认只回主线（不被教学会话污染）
  final latest = await repo.latestSession('study_plan');
  expect(latest!.id, mainlineId);

  // latestSession 关闭主线过滤时能看到教学会话
  final any = await repo.latestSession('study_plan', mainlineOnly: false);
  expect(any!.id, teachingId); // 教学会话更新晚，按 updated_at 排前
  await sdb.close();
});
```
（`ChatMessage` 有 const 构造；若 const 断言报错，去掉 `const` 即可。）

- [ ] **Step 3: 运行确认失败**

Run: `cd packages/study_engine && flutter test test/chat_repository_test.dart`
Expected: 编译失败（`findTeachingSession` / `createSession` 无 topicId 参数未定义）。

- [ ] **Step 4: 实现 ChatRepository 扩展**

`packages/study_engine/lib/src/repos/chat_repository.dart`：
```dart
Future<int> createSession(String scenarioId, String title, {int? topicId}) async {
  final now = DateTime.now().millisecondsSinceEpoch;
  return _db.db.insert('chat_session', {
    'scenario_id': scenarioId,
    'title': title,
    'created_at': now,
    'updated_at': now,
    if (topicId != null) 'topic_id': topicId,
  });
}

/// 最近更新的某场景会话（用于 App 重启续聊）。
/// [mainlineOnly] 为 true（默认）时只取 topic_id IS NULL 的主线会话，
/// 避免把知识点教学会话误当主线恢复；false 时取任意会话。
Future<ChatSession?> latestSession(String scenarioId,
    {bool mainlineOnly = true}) async {
  final rows = await _db.db.query(
    'chat_session',
    where: mainlineOnly
        ? 'scenario_id = ? AND topic_id IS NULL'
        : 'scenario_id = ?',
    whereArgs: [scenarioId],
    orderBy: 'updated_at DESC, id DESC',
    limit: 1,
  );
  if (rows.isEmpty) return null;
  return ChatSession.fromMap(rows.first);
}

/// 某知识点的专属教学会话（scenario_id='study_plan' 且 topic_id=?）。
/// 命中即复用（每 topic 至多一条），未命中返回 null。
Future<ChatSession?> findTeachingSession(int topicId) async {
  final rows = await _db.db.query(
    'chat_session',
    where: 'scenario_id = ? AND topic_id = ?',
    whereArgs: ['study_plan', topicId],
    orderBy: 'updated_at DESC, id DESC',
    limit: 1,
  );
  if (rows.isEmpty) return null;
  return ChatSession.fromMap(rows.first);
}
```
注：`ChatSession.fromMap` 只读 known keys，新列 `topic_id` 会安全忽略，无需改 model。

- [ ] **Step 5: 运行确认通过**

Run: `cd packages/study_engine && flutter test test/chat_repository_test.dart`
Expected: PASS（全部）。

- [ ] **Step 6: 全量 engine 测试回归**

Run: `cd packages/study_engine && flutter test`
Expected: All tests passed（含 db_test / 迁移测试）。

- [ ] **Step 7: Commit**

```bash
git add packages/study_engine/lib/src/db/database_migrations.dart packages/study_engine/lib/src/repos/chat_repository.dart packages/study_engine/test/chat_repository_test.dart
git commit -m "feat(engine): chat_session 加 topic_id 列(v11) + ChatRepository 教学会话查询"
```

---

### Task 2: ChatSessionNotifier 改造 + topicTeachingProvider

**Files:**
- Modify: `study_buddy/lib/core/providers/chat_session_provider.dart`
- Test: `study_buddy/test/core/providers/chat_session_provider_test.dart`

**Interfaces:**
- Consumes: Task 1 的 `createSession(topicId)`、`findTeachingSession`、`latestSession(mainlineOnly)`。
- Produces（后续任务依赖）:
  - `Future<void> ChatSessionNotifier.startTeaching(int topicId)`
  - `final topicTeachingProvider = StateNotifierProvider<ChatSessionNotifier, ChatSessionState>`
  - `clear()` 重置 `_topicId`；`send` 透传 `_topicId` 给 `AgentSession.run`

- [ ] **Step 1: 写失败测试（恢复路径：有历史 → 零 LLM）**

`chat_session_provider_test.dart` 顶部 import 区补：
```dart
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:study_buddy/core/providers/database_provider.dart';
```
`main()` 内 `setUpAll(sqfliteFfiInit);` 加在 `main()` 开头（若 main 已有其它结构，追加一行即可）。

`main()` 内新增两个测试（替换/补充原 `startTopicTeaching` 测试，见 Step 2）：
```dart
test('startTeaching:存在历史教学会话时直接恢复,不调用 LLM', () async {
  // 内存库预置 topicId=42 的教学会话（user+assistant）
  final sdb = await StudyDatabase.open(
      factory: databaseFactoryFfi, path: inMemoryDatabasePath);
  addTearDown(sdb.close);
  final seedRepo = ChatRepository(sdb);
  final sid = await seedRepo.createSession('study_plan', '教学', topicId: 42);
  await seedRepo.addMessage(sid, const ChatMessage(role: 'user', content: '开场指令'));
  await seedRepo.addMessage(sid, const ChatMessage(role: 'assistant', content: '上次讲解内容'));

  _FakeAgentSession? captured;
  final container = ProviderContainer(overrides: [
    agentSessionProvider.overrideWith((ref) =>
        captured = _FakeAgentSession(ref, const [])),
    databaseProvider.overrideWith((ref) async => sdb),
  ]);
  addTearDown(container.dispose);

  final notifier = container.read(topicTeachingProvider.notifier);
  await notifier.startTeaching(42);

  final state = container.read(topicTeachingProvider);
  expect(state.messages, hasLength(2));
  expect(state.messages[1].content, '上次讲解内容');
  expect(state.busy, isFalse);
  // 关键：零 LLM 调用
  expect(captured!.receivedMessages, isEmpty);
});

test('startTeaching:无历史时发开场并等首个 TextDelta resolve,透传 topicId', () async {
  final events = <AgentEvent>[
    TextDeltaEvent('开场'),
    TextDeltaEvent('引导'),
    AgentDoneEvent('开场引导'),
  ];
  final sdb = await StudyDatabase.open(
      factory: databaseFactoryFfi, path: inMemoryDatabasePath);
  addTearDown(sdb.close);
  _FakeAgentSession? captured;
  final container = ProviderContainer(overrides: [
    agentSessionProvider.overrideWith((ref) =>
        captured = _FakeAgentSession(ref, events)),
    databaseProvider.overrideWith((ref) async => sdb),
  ]);
  addTearDown(container.dispose);

  final notifier = container.read(topicTeachingProvider.notifier);
  await notifier.startTeaching(42);
  await Future<void>.delayed(const Duration(milliseconds: 20)); // 事件流走完

  final state = container.read(topicTeachingProvider);
  expect(state.messages, hasLength(2)); // 开场 user + assistant
  final userContent = state.messages[0].content as List<ContentPart>;
  expect(userContent.whereType<TextPart>().map((p) => p.text).join(), contains('场景'));
  expect(state.messages[1].content, '开场引导');
  expect(state.busy, isFalse);
  // 教学轮透传 topicId=42
  expect(captured!.receivedTopicIds, [42]);
});
```

- [ ] **Step 2: 运行确认失败**

Run: `cd study_buddy && flutter test test/core/providers/chat_session_provider_test.dart`
Expected: 编译失败（`topicTeachingProvider` / `startTeaching` 未定义）。

- [ ] **Step 3: 实现 ChatSessionNotifier 改造**

`chat_session_provider.dart`：
1. 字段改名：`int? _teachingTopicId;` → `int? _topicId;`（注释：教学 topic，`startTeaching` 设置、`clear` 重置）。
2. 新增 `Completer<void>? _firstToken;`（当前 startTeaching 的首个文字 token 信号）。
3. `_initSession` 内 `repo.createSession('study_plan', _truncateTitle(firstText))` →
   `repo.createSession('study_plan', _truncateTitle(firstText), topicId: _topicId)`。
4. `send` 内 `topicId: _teachingTopicId` → `topicId: _topicId`。
5. `_onEvent` 顶部（`state = chatSessionReducer(...)` 之前）加（首个文字 token 放行；
   纯工具轮/整轮结束/错误作为兜底放行，避免 startTeaching 永挂）：
```dart
if (_firstToken != null && !_firstToken!.isCompleted) {
  if (event is TextDeltaEvent || event is AgentDoneEvent) {
    _firstToken!.complete();
  } else if (event is AgentErrorEvent) {
    _firstToken!.completeError(event.message);
  }
}
```
6. `send` 的流回调与构造期 catch 补 `_firstToken` 放行：
   - `onError: (e, _)`：进入 `_onError` 前 `if (_firstToken 未完成) _firstToken!.completeError('$e');`
   - `catch (e)`（构造期）：现有回滚前 `if (_firstToken 未完成) _firstToken!.completeError('$e');`
7. `clear()` 内：`_teachingTopicId = null;` → `_topicId = null;`，并在其后加：
```dart
if (_firstToken != null && !_firstToken!.isCompleted) {
  _firstToken!.completeError(StateError('会话已重置'));
}
_firstToken = null;
```
8. 把 `startTopicTeaching(int topicId)` 替换为 `startTeaching(int topicId)`：
```dart
/// 启动「知识点教学模式」（详情页【为什么？】入口）。
///
/// 返回的 Future 在「可展示」时 resolve：已有历史教学会话则直接恢复（零 LLM 调用）；
/// 无历史则新建教学会话 + 发开场消息，等首个文字 token（TextDeltaEvent）到达即 resolve
/// （不等整轮结束）。失败时抛出（构造期抛错 / AgentErrorEvent / 会话被 clear 重置）。
Future<void> startTeaching(int topicId) async {
  clear();
  _topicId = topicId;
  // 1) 先尝试恢复该 topic 的历史教学会话（有则直接展示，不请求 LLM）
  if (await _tryRestoreTeaching(topicId)) return;
  // 2) 无历史：新建教学会话 + 发开场消息，等首个文字 token
  final firstToken = Completer<void>();
  _firstToken = firstToken;
  // unawaited 后由 _onEvent 完成 _firstToken；.catchError 兜底防未处理异常
  // （_firstToken 的 completeError 由 _onEvent 的 AgentErrorEvent / send 构造期 catch 完成）。
  unawaited(send(_teachingOpeningPrompt).catchError((Object _) {}));
  await firstToken.future;
}

/// 尝试恢复该知识点已持久化的教学会话。命中且有消息 → 载入 state 返回 true。
/// 无会话 / 无消息 / 读库失败 → 返回 false（调用方走开场路径）。
Future<bool> _tryRestoreTeaching(int topicId) async {
  try {
    final db = await _ref.read(databaseProvider.future);
    final repo = ChatRepository(db);
    final session = await repo.findTeachingSession(topicId);
    if (session == null) return false;
    final msgs = await repo.loadMessages(session.id);
    if (msgs.isEmpty) return false;
    _sessionId = session.id;
    state = ChatSessionState(messages: msgs, sessionId: session.id);
    return true;
  } catch (e, st) {
    LoggerService.instance.w('教学会话恢复失败: $e',
        category: LogCategory.ai, stackTrace: st.toString());
    return false;
  }
}
```
9. 文件末尾 `currentChatProvider` 定义后加：
```dart
/// 知识点教学会话（详情页【为什么？】入口）：独立于主线的专属会话，
/// 与 currentChatProvider 完全隔离，互不覆盖。topicId 由 startTeaching 动态设置。
final topicTeachingProvider =
    StateNotifierProvider<ChatSessionNotifier, ChatSessionState>((ref) {
  return ChatSessionNotifier(ref);
});
```
10. 删除原 `startTopicTeaching` 方法及其旧测试引用（Step 1 已用新测试覆盖）。

- [ ] **Step 4: 清理旧测试**

`chat_session_provider_test.dart` 中删除原 `test('startTopicTeaching: 清空旧会话 + 发开场消息 + run 收到 topicId', ...)` 整块（Step 1 的两个测试已取代它）。

- [ ] **Step 5: 运行确认通过**

Run: `cd study_buddy && flutter test test/core/providers/chat_session_provider_test.dart`
Expected: PASS（全部，含新增两个测试）。

- [ ] **Step 6: Commit**

```bash
git add study_buddy/lib/core/providers/chat_session_provider.dart study_buddy/test/core/providers/chat_session_provider_test.dart
git commit -m "feat(agent): startTeaching 恢复/开场二段式 + 独立 topicTeachingProvider"
```

---

### Task 3: 详情页按钮等待态 + 条件跳转

**Files:**
- Modify: `study_buddy/lib/features/knowledge/topic_detail_page.dart`
- Test: `study_buddy/test/features/knowledge/topic_detail_page_test.dart`

**Interfaces:**
- Consumes: Task 2 的 `topicTeachingProvider`、`startTeaching(int)`；现有 `showAiPanel(context, topicId:)`。
- Produces: 无新接口（UI 行为变化：点击后 loading → 首个 token/历史就绪后 push `/ai`）。

- [ ] **Step 1: 写失败测试**

`topic_detail_page_test.dart`：
1. 顶部 import 补：
```dart
import 'package:study_buddy/core/providers/agent_session_provider.dart';
import 'package:study_engine/study_engine.dart';
```
2. 加 fake（文件末尾，main 外）：
```dart
/// 假 AgentSession：事件流立即放完，记录收到的 topicId。
class _FakeAgentSession extends AgentSession {
  _FakeAgentSession(super.ref);
  final List<int?> receivedTopicIds = [];
  @override
  Future<AgentSessionHandle> run(List<ChatMessage> messages,
      {int? chatSessionId, int? planId, DateTime? today, int? topicId}) async {
    receivedTopicIds.add(topicId);
    return AgentSessionHandle(
      stream: Stream.fromIterable(
          [TextDeltaEvent('开场'), AgentDoneEvent('开场')]),
    );
  }
}
```
3. 把原测试 `【为什么？】按钮渲染并点击跳转 /ai 教学入口` 改为：
```dart
testWidgets('【为什么？】:点击后按钮变「正在思考」,AI 首个 token 到达才跳转 /ai', (tester) async {
  final container = ProviderContainer(overrides: [
    databaseProvider.overrideWith((ref) async => sdb),
    agentSessionProvider.overrideWith((ref) => _FakeAgentSession(ref)),
  ]);
  addTearDown(container.dispose);

  await pumpDetailPage(tester, container);

  expect(find.byKey(const ValueKey('why-button')), findsOneWidget);
  expect(find.text('为什么？'), findsOneWidget);

  await tester.tap(find.byKey(const ValueKey('why-button')));
  await tester.pump();
  // 等待态：按钮变「正在思考怎么和你解释..」（未立即跳转）
  expect(find.text('正在思考怎么和你解释..'), findsOneWidget);
  expect(find.text('ai-page'), findsNothing);

  // startTeaching 的恢复查询是真实异步（sqflite isolate），runAsync 推进；
  // fake 事件流首个 TextDelta 到达 → resolve → push /ai。
  await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)));
  await tester.pumpAndSettle();
  expect(find.text('ai-page'), findsOneWidget);
});
```
注：原 `/ai` 路由仍是占位页（`Scaffold(body: Center(child: Text('ai-page')))`），跳转断言用 `find.text('ai-page')`。

- [ ] **Step 2: 运行确认失败**

Run: `cd study_buddy && flutter test test/features/knowledge/topic_detail_page_test.dart`
Expected: FAIL（点击后找不到「正在思考怎么和你解释..」，或未跳转）。

- [ ] **Step 3: 实现详情页改造**

`topic_detail_page.dart`：
1. `_TopicDetailPageState` 加字段：
```dart
/// 教学启动阶段：idle=未启动；starting=等待 AI 首个 token（按钮 loading，防重复点击）。
bool _teachingStarting = false;
```
2. 新增方法：
```dart
/// 【为什么？】入口：先启动教学（恢复历史 或 等 AI 首个 token），再跳转 AI 页。
/// 等待期间按钮变「正在思考怎么和你解释..」；失败恢复按钮并提示，不跳转。
Future<void> _startTeaching() async {
  if (_teachingStarting) return;
  setState(() => _teachingStarting = true);
  try {
    await ref.read(topicTeachingProvider.notifier).startTeaching(widget.topicId);
    if (!mounted) return;
    await showAiPanel(context, topicId: widget.topicId);
  } catch (e) {
    LoggerService.instance.w('教学启动失败: $e',
        category: LogCategory.ai, tags: const ['teaching-start']);
  } finally {
    if (mounted) setState(() => _teachingStarting = false);
  }
}
```
3. 按钮改：
```dart
FilledButton.tonalIcon(
  key: const ValueKey('why-button'),
  onPressed: _teachingStarting ? null : _startTeaching,
  icon: _teachingStarting
      ? const SizedBox(
          width: 18, height: 18,
          child: CircularProgressIndicator(strokeWidth: 2))
      : const Icon(Icons.emoji_objects_outlined),
  label: Text(
    _teachingStarting ? '正在思考怎么和你解释..' : '为什么？',
    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
  ),
  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
),
```
4. import 区补：`import '../../core/providers/agent_session_provider.dart';`（如未引入）与 `../../core/services/logger_service.dart`（如未引入）；`topicTeachingProvider` 从 `chat_session_provider.dart` 引入：
```dart
import '../../core/providers/chat_session_provider.dart';
```
（若 `showAiPanel` 已 import，`ai_panel_sheet.dart` 已存在。）

- [ ] **Step 4: 运行确认通过**

Run: `cd study_buddy && flutter test test/features/knowledge/topic_detail_page_test.dart`
Expected: PASS。

- [ ] **Step 5: Commit**

```bash
git add study_buddy/lib/features/knowledge/topic_detail_page.dart study_buddy/test/features/knowledge/topic_detail_page_test.dart
git commit -m "feat(knowledge): 为什么按钮等待态「正在思考」+ 首个 token 后跳转 AI 页"
```

---

### Task 4: AiChatPage — provider 切换 + 顶部知识卡 + hydrate 区分 + 兜底启动

**Files:**
- Modify: `study_buddy/lib/features/external_qbank/ai_panel_sheet.dart`
- Test: `study_buddy/test/features/external_qbank/ai_panel_sheet_test.dart`

**Interfaces:**
- Consumes: Task 2 的 `topicTeachingProvider` / `startTeaching`；`TopicRepository.findById`；`databaseProvider`。
- Produces: 私有 `_TopicHeaderCard`（不导出）。

- [ ] **Step 1: 写失败测试**

`ai_panel_sheet_test.dart`：
1. 顶部 import 补：
```dart
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:study_buddy/core/providers/database_provider.dart';
```
2. `main()` 开头加 `setUpAll(sqfliteFfiInit);`。
3. 新测试（知识卡渲染 + 教学走独立 provider）：
```dart
testWidgets('教学入口:顶部可折叠知识卡渲染,折叠后只留标题;会话走 topicTeachingProvider', (tester) async {
  // 内存库 seed 一个 topic（id 记为 topicId）
  final sdb = await StudyDatabase.open(
      factory: databaseFactoryFfi, path: inMemoryDatabasePath);
  addTearDown(sdb.close);
  final now = DateTime.now();
  final catId = await sdb.db.insert(
      'category', Category(parentId: null, name: '数学', createdAt: now).toMap());
  final topicId = await sdb.db.insert(
      'topic',
      Topic(
        categoryId: catId,
        question: '夹逼定理的夹逼对象是什么？',
        title: '夹逼定理',
        summary: '若 f≤g≤h 且 lim f=lim h=L，则 lim g=L。',
        createdAt: now,
        updatedAt: now,
      ).toMap());

  final container = ProviderContainer(overrides: [
    agentSessionProvider.overrideWith((ref) => _FakeAgentSession(ref)),
    databaseProvider.overrideWith((ref) async => sdb),
  ]);
  addTearDown(container.dispose);

  await pumpPanel(tester, container: container, topicId: topicId);
  await tester.pumpAndSettle();

  // 顶部知识卡：标题可见（展开态）
  expect(find.text('夹逼定理'), findsWidgets);

  // 折叠：点 toggle → 引子缩略消失（折叠态仅剩标题条）
  await tester.tap(find.byKey(const ValueKey('topic-card-toggle')));
  await tester.pumpAndSettle();
  expect(find.textContaining('夹逼定理的夹逼对象'), findsNothing);
});
```
4. 改原测试 `教学入口:带 topicId 进入后 AI 自动开场,开场指令渲染为引导横幅`：
   - container overrides 加 `databaseProvider.overrideWith((ref) async => 空内存库)`（`await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath)`，`addTearDown(sdb.close)`）。
   - 末尾断言 `final state = container.read(currentChatProvider);` → `container.read(topicTeachingProvider);`（教学会话在独立 provider）。

- [ ] **Step 2: 运行确认失败**

Run: `cd study_buddy && flutter test test/features/external_qbank/ai_panel_sheet_test.dart`
Expected: FAIL（`topic-card-toggle` 不存在 / 教学消息不在 `topicTeachingProvider`）。

- [ ] **Step 3: 实现 AiChatPage 改造**

`ai_panel_sheet.dart`：
1. import 补：`import 'dart:async';`（已有）、`import '../../core/providers/database_provider.dart';`、`import '../../core/widgets/...'`（无新增）。`topicTeachingProvider` 已随 `chat_session_provider.dart` import 引入。
2. `_AiChatPageState` 加字段：
```dart
/// 会话状态来源：教学入口（initialTopicId != null）→ topicTeachingProvider，否则主线。
late final StateNotifierProvider<ChatSessionNotifier, ChatSessionState> _chatProvider;
bool get _isTeaching => widget.initialTopicId != null;
```
3. `initState` 改造：
```dart
_chatProvider = _isTeaching ? topicTeachingProvider : currentChatProvider;
// 冷启动恢复最近会话（续聊）：仅主线；教学路径由 startTeaching 自行恢复历史。
if (!_isTeaching) {
  ref.read(_chatProvider.notifier).hydrate();
}
_pendingImage = widget.initialScreenshot;
_teachingOpening = _isTeaching;
if (_isTeaching) {
  // 教学兜底启动：从详情页进入时 startTeaching 已完成/进行中则跳过；
  // 深链/分享直达空态时补发开场。延迟到首帧后执行（send 修改 provider，
  // initState 期间违反 Riverpod 3 构建期约束）。
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!mounted) return;
    final s = ref.read(topicTeachingProvider);
    if (!s.busy && s.messages.isEmpty) {
      unawaited(
          ref.read(topicTeachingProvider.notifier).startTeaching(widget.initialTopicId!));
    }
  });
}
```
4. `ref.listenManual(currentChatProvider, ...)` → `ref.listenManual(_chatProvider, ...)`。
5. build 里 `final state = ref.watch(currentChatProvider);` → `final state = ref.watch(_chatProvider);`。
6. 其余 `ref.read(currentChatProvider...)`（AppBar 新对话 clear、`_send`、`_submitFreeAnswer`、AskUserCard `respondToAsk`）全部 → `ref.read(_chatProvider...)`。
7. body 顶部（`if (showEmptyState)` 之前，`Column` 内第一项）加：
```dart
// 教学入口：顶部常驻可折叠知识卡。
if (_isTeaching) _TopicHeaderCard(topicId: widget.initialTopicId!),
```

- [ ] **Step 4: 实现 _TopicHeaderCard 组件**

`ai_panel_sheet.dart` 末尾（私有 widget 区）新增：
```dart
// ─────────────────────────────────────────────────────────────
// 私有 widget：教学入口顶部知识卡（可折叠）
// ─────────────────────────────────────────────────────────────

/// 教学入口顶部知识卡：默认展开（标题 + 引子/答案缩略），可折叠成一行标题条，
/// 点卡片主体跳回知识点详情页。数据来自 TopicRepository.findById。
class _TopicHeaderCard extends ConsumerStatefulWidget {
  const _TopicHeaderCard({required this.topicId});
  final int topicId;

  @override
  ConsumerState<_TopicHeaderCard> createState() => _TopicHeaderCardState();
}

class _TopicHeaderCardState extends ConsumerState<_TopicHeaderCard> {
  bool _expanded = true;

  Future<Topic?> _loadTopic() async {
    final db = await ref.read(databaseProvider.future);
    return TopicRepository(db).findById(widget.topicId);
  }

  /// 剥掉常见 Markdown 记号，供缩略文本用。
  String _stripMarkdown(String s) =>
      s.replaceAll(RegExp(r'[*_`#>\-\[\]()]'), '').trim();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      color: cs.surfaceContainerLow,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: cs.outlineVariant, width: 0.5),
      ),
      child: FutureBuilder<Topic?>(
        future: _loadTopic(),
        builder: (context, snap) {
          final title = snap.data?.title ?? '知识点';
          return InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => context.push('/topic/${widget.topicId}'),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.emoji_objects_outlined,
                      size: 16, color: cs.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall
                                ?.copyWith(fontWeight: FontWeight.w700)),
                        if (_expanded && snap.hasData) ...[
                          const SizedBox(height: 4),
                          Text('引子：${_stripMarkdown(snap.data!.question)}',
                              maxLines: 2, overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall
                                  ?.copyWith(color: cs.onSurfaceVariant)),
                          const SizedBox(height: 2),
                          Text('答案：${_stripMarkdown(snap.data!.summary)}',
                              maxLines: 2, overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall
                                  ?.copyWith(color: cs.onSurfaceVariant)),
                        ],
                      ],
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('topic-card-toggle'),
                    visualDensity: VisualDensity.compact,
                    iconSize: 18,
                    icon: Icon(_expanded
                        ? Icons.expand_less
                        : Icons.expand_more),
                    tooltip: _expanded ? '收起' : '展开',
                    onPressed: () => setState(() => _expanded = !_expanded),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
```

- [ ] **Step 5: 运行确认通过**

Run: `cd study_buddy && flutter test test/features/external_qbank/ai_panel_sheet_test.dart`
Expected: PASS。

- [ ] **Step 6: 相关回归 + 全量测试**

Run: `cd study_buddy && flutter test`
Expected: All tests passed（`topic_detail_page_test` / `chat_session_provider_test` / `ai_panel_sheet_test` / 其余无回归）。

- [ ] **Step 7: Commit**

```bash
git add study_buddy/lib/features/external_qbank/ai_panel_sheet.dart study_buddy/test/features/external_qbank/ai_panel_sheet_test.dart
git commit -m "feat(ai): 教学入口顶部可折叠知识卡 + provider 按入口切换 + 兜底启动"
```

---

## 验收清单（对照 Spec）

- [ ] 点【为什么？】→ 按钮变「正在思考怎么和你解释..」并禁用（不立即跳转）。
- [ ] AI 首个文字 token 到达（或历史恢复完成）→ 才 push `/ai`。
- [ ] AI 页顶部常驻可折叠知识卡（默认展开标题+引子+答案缩略；折叠只留标题；点卡片回详情页）。
- [ ] 教学会话走 `topicTeachingProvider`，主线 `currentChatProvider` 不被覆盖。
- [ ] 教学会话落库带 `topic_id`；主线 `hydrate()` 只恢复 `topic_id IS NULL`。
- [ ] 再次点【为什么？】→ 直接恢复上次记录（fake 断言 `receivedMessages` 为空 = 零 LLM 调用）。
- [ ] 复用历史后可继续输入追问（同一 sessionId + topicId 续聊）。
- [ ] 教学启动失败 → 按钮恢复可点 + SnackBar 提示（无跳转）。
- [ ] 深链/分享直达 `/ai`（带 topicId）→ AiChatPage 兜底启动教学。
- [ ] 全量测试通过，无回归。
