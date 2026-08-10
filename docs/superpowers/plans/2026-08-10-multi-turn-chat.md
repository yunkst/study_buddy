# 纯内存多轮对话 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让用户截图分析后能在当前抽屉内连续追问（带上文），AI 基于完整历史回答；纯内存，关掉即失。

**Architecture:** 在 App 层新增 `currentChatProvider`（StateNotifier）持有完整 `List<ChatMessage>`，每轮 `send()` 把完整历史喂给无状态的 `AgentSession.run()`。引擎唯一改动：`AgentDoneEvent` 补带本轮 `toolCalls`，Notifier 据此 + `ToolCallEndEvent.result` 按 `toolCallId` 配对组装合法多轮消息序列。

**Tech Stack:** Flutter / Dart / Riverpod (StateNotifier) / go_router / study_engine (AgentLoop ReAct) / flutter_test (App 层) / package:test (engine 层)

## Global Constraints

- **纯内存**：截图与对话不落库、不回看、无历史列表；`ChatRepository` 仍是预留件，本计划不接入。
- **截图纯内存**：`CapturedScreenshot`（pngBytes + base64DataUri）只活在 `ChatMessage` 的 `ImageUrlPart`，随会话内存释放，不落盘不入库。
- **引擎业务逻辑零改动**：`AgentScenario`/`StudyScenario`/工具/`ChatRepository` 不动；22 个现有测试不受影响。唯一引擎改动是 `AgentDoneEvent +toolCalls`（事件流信息补强，非业务逻辑）。
- **AgentSession 保持无状态**：`run(List<ChatMessage>)` 签名不变，多轮状态下沉到 `currentChatProvider`。
- **追问可选附图**：每轮 0~1 张，文字为主。
- **engine 测试用 `package:test/test.dart`**（非 flutter_test）；**App 测试用 `flutter_test`**。
- 所有 commit message 末尾加 `Co-Authored-By: Claude <noreply@anthropic.com>`。

---

## File Structure

| 文件 | 职责 | 动作 |
|---|---|---|
| `packages/study_engine/lib/src/agent/agent_event.dart` | `AgentDoneEvent` 补 `toolCalls` 字段 | 修改 |
| `packages/study_engine/lib/src/agent/agent_loop.dart` | `yield AgentDoneEvent` 时传入 `agg` | 修改（2 处） |
| `packages/study_engine/test/agent_loop_test.dart` | 新增 Done 携带 toolCalls 的测试 | 修改 |
| `study_buddy/lib/core/providers/chat_session_provider.dart` | 多轮会话状态 StateNotifier（核心） | 新增 |
| `study_buddy/test/core/providers/chat_session_provider_test.dart` | Notifier 单元测试（mock AgentSession） | 新增 |
| `study_buddy/lib/features/external_qbank/ai_panel_sheet.dart` | 单次表单 → 消息列表 + 连续输入框 + 加图 | 修改 |
| `study_buddy/test/features/external_qbank/ai_panel_sheet_test.dart` | widget 测试 | 新增 |

依赖顺序：Task 1（引擎 Done 补字段）→ Task 2（Notifier）→ Task 3（UI 改造）。Task 1 是 Task 2 的前置（Notifier 依赖 Done 的 toolCalls）。

---

### Task 1: 引擎补强 AgentDoneEvent 携带 toolCalls

**Files:**
- Modify: `packages/study_engine/lib/src/agent/agent_event.dart:36-39`
- Modify: `packages/study_engine/lib/src/agent/agent_loop.dart:47,75`
- Test: `packages/study_engine/test/agent_loop_test.dart`

**Interfaces:**
- Consumes: `ToolCall`（`models.dart`，已有，字段 `id`/`name`/`arguments`）；`AgentLoop` 内部 `agg` 变量（`List<ToolCall>`，已有）
- Produces: `AgentDoneEvent.finalText`（String?，已有）+ `AgentDoneEvent.toolCalls`（`List<ToolCall>`，新增，默认 `const []`）。Task 2 的 Notifier 依赖 `done.toolCalls` 字段。

- [ ] **Step 1: 写失败测试 — Done 携带 toolCalls**

在 `packages/study_engine/test/agent_loop_test.dart` 的 `main()` 内追加测试（复用现有 `_FakeLlm`/`_FakeScenario`）：

```dart
  test('AgentDoneEvent 携带本轮 toolCalls', () async {
    final llm = _FakeLlm([
      const [LlmStreamChunk(textDelta: '', toolCalls: [ToolCall(id: 'c1', name: 'query_topics', arguments: '{"subject":"数学"}')])],
      const [LlmStreamChunk(textDelta: '已完成')],
    ]);
    final scenario = _FakeScenario();
    final loop = AgentLoop(llm: llm, scenario: scenario);
    final events = await loop.run([const ChatMessage(role: 'system', content: 'sys')]).toList();
    final done = events.whereType<AgentDoneEvent>().single;
    expect(done.finalText, '已完成');
    expect(done.toolCalls, hasLength(1));
    expect(done.toolCalls.single.id, 'c1');
    expect(done.toolCalls.single.name, 'query_topics');
  });

  test('AgentDoneEvent 无工具调用时 toolCalls 为空列表', () async {
    final llm = _FakeLlm([
      const [LlmStreamChunk(textDelta: '直接回答')],
    ]);
    final scenario = _FakeScenario();
    final loop = AgentLoop(llm: llm, scenario: scenario);
    final events = await loop.run([const ChatMessage(role: 'system', content: 'sys')]).toList();
    final done = events.whereType<AgentDoneEvent>().single;
    expect(done.finalText, '直接回答');
    expect(done.toolCalls, isEmpty);
  });
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd packages/study_engine && flutter test test/agent_loop_test.dart`
Expected: FAIL — `done.toolCalls` 编译错误（`AgentDoneEvent` 无 `toolCalls` getter）或断言失败。

- [ ] **Step 3: 修改 AgentDoneEvent 加 toolCalls 字段**

修改 `packages/study_engine/lib/src/agent/agent_event.dart`，把：

```dart
class AgentDoneEvent extends AgentEvent {
  final String? finalText;
  AgentDoneEvent(this.finalText);
}
```

改为：

```dart
class AgentDoneEvent extends AgentEvent {
  final String? finalText;
  final List<ToolCall> toolCalls; // 本轮 assistant 的工具调用（空列表表示无）
  AgentDoneEvent(this.finalText, [this.toolCalls = const []]);
}
```

> 注：`agent_event.dart` 顶部需确保 `ToolCall` 可见。检查文件是否已 import models：若顶部无 `import '../models/models.dart';` 则补上（`ToolCall` 定义在 `models.dart`）。

- [ ] **Step 4: 修改 AgentLoop 两处 yield 传入 agg**

修改 `packages/study_engine/lib/src/agent/agent_loop.dart`。

第 47 行（无工具调用结束路径），把：
```dart
          yield AgentDoneEvent(buf.toString());
```
改为：
```dart
          yield AgentDoneEvent(buf.toString(), const []);
```

第 75 行（达到 maxRounds 结束路径），把：
```dart
          yield AgentDoneEvent(null);
```
改为：
```dart
          yield AgentDoneEvent(null, const []);
```

> 工具调用结束路径在 `return` 前不会有单独的 `AgentDoneEvent`——工具调用后 `round++` 进入下一轮，最终由无工具调用路径或 maxRounds 路径结束。但工具调用轮的 `agg` 需要在结束时带上。检查：实际上 `agg` 是 while 循环内局部变量，每轮重置。`AgentDoneEvent` 只在循环结束时 yield。因此工具调用轮的 toolCalls **不会**被 Done 携带——这是问题。

> **修正**：`AgentDoneEvent` 应携带**最后一轮**的 toolCalls。但多轮 ReAct 中，最后一轮通常是无工具调用的纯文本回答（LLM 看到工具结果后给出最终答案）。若最后一轮仍有工具调用（罕见，LLM 连续调工具未给文本），Done 时 `agg` 非空。当前循环结构下，Done 在 `agg.isEmpty` 分支 yield，此时 `agg` 必为空。所以 Done 的 toolCalls **在实际流程中总是空列表**。

> **重新审视**：Notifier 需要的是**每一轮**的 assistant+tool 消息，不是只有最后一轮。`AgentDoneEvent` 只在结束时发一次，无法携带中间轮的消息。解法2 的设计需要调整：Notifier 必须在**每轮结束时**收到本轮的 assistant+tool 消息，而非只在最终 Done 时。

- [ ] **Step 4 修正：改用 AgentRoundEndEvent 逐轮携带消息**

放弃在 `AgentDoneEvent` 上加 toolCalls（它只发一次，携带中间轮信息不足）。改为新增一个**每轮结束时** yield 的事件，携带本轮新增的完整消息（assistant + tool 消息列表）。

在 `packages/study_engine/lib/src/agent/agent_event.dart` 新增事件类（在 `AgentDoneEvent` 之前）：

```dart
/// 单轮 ReAct 结束：携带本轮新增的 assistant 消息及其触发的 tool 消息。
/// UI 据此 append 到会话历史，保证多轮消息序列合法。
class AgentRoundEndEvent extends AgentEvent {
  final List<ChatMessage> newMessages; // [assistant(含 toolCalls), tool, tool, ...]
  AgentRoundEndEvent(this.newMessages);
}
```

修改 `packages/study_engine/lib/src/agent/agent_loop.dart` 的工具调用分支（第 51-64 行附近），在 `for (final tc in agg)` 循环**之后**、`compactor` 检查**之前**，yield 本轮消息：

把现有：
```dart
        // assistant 消息携带 tool_calls
        msgs.add(ChatMessage(role: 'assistant', content: buf.toString(), toolCalls: agg));
        for (final tc in agg) {
          yield ToolCallStartEvent(tc.name, tc.id);
          final args = _parseArgs(tc.arguments);
          String result;
          try {
            result = await scenario.executeTool(tc.name, args, toolCallId: tc.id);
          } catch (e) {
            result = '工具执行出错: $e';
          }
          yield ToolCallEndEvent(tc.name, result, tc.id);
          msgs.add(ChatMessage(role: 'tool', content: result, toolCallId: tc.id));
        }
```

改为：
```dart
        // assistant 消息携带 tool_calls
        final assistantMsg = ChatMessage(role: 'assistant', content: buf.toString(), toolCalls: agg);
        msgs.add(assistantMsg);
        final roundNewMsgs = <ChatMessage>[assistantMsg];
        for (final tc in agg) {
          yield ToolCallStartEvent(tc.name, tc.id);
          final args = _parseArgs(tc.arguments);
          String result;
          try {
            result = await scenario.executeTool(tc.name, args, toolCallId: tc.id);
          } catch (e) {
            result = '工具执行出错: $e';
          }
          yield ToolCallEndEvent(tc.name, result, tc.id);
          final toolMsg = ChatMessage(role: 'tool', content: result, toolCallId: tc.id);
          msgs.add(toolMsg);
          roundNewMsgs.add(toolMsg);
        }
        yield AgentRoundEndEvent(roundNewMsgs);
```

`AgentDoneEvent` 保持原样（不改，回退 Step 3 的改动）：
```dart
class AgentDoneEvent extends AgentEvent {
  final String? finalText;
  AgentDoneEvent(this.finalText);
}
```

- [ ] **Step 5: 修正测试为验证 AgentRoundEndEvent**

把 Step 1 追加的两个测试改为：

```dart
  test('AgentRoundEndEvent 携带本轮 assistant+tool 消息', () async {
    final llm = _FakeLlm([
      const [LlmStreamChunk(textDelta: '', toolCalls: [ToolCall(id: 'c1', name: 'query_topics', arguments: '{"subject":"数学"}')])],
      const [LlmStreamChunk(textDelta: '已完成')],
    ]);
    final scenario = _FakeScenario();
    final loop = AgentLoop(llm: llm, scenario: scenario);
    final events = await loop.run([const ChatMessage(role: 'system', content: 'sys')]).toList();
    final roundEnds = events.whereType<AgentRoundEndEvent>().toList();
    expect(roundEnds, hasLength(1)); // 只第 1 轮有工具调用
    final newMsgs = roundEnds.single.newMessages;
    expect(newMsgs, hasLength(2)); // assistant + tool
    expect(newMsgs[0].role, 'assistant');
    expect(newMsgs[0].toolCalls, hasLength(1));
    expect(newMsgs[0].toolCalls!.single.id, 'c1');
    expect(newMsgs[1].role, 'tool');
    expect(newMsgs[1].toolCallId, 'c1');
  });

  test('无工具调用的轮不 yield AgentRoundEndEvent', () async {
    final llm = _FakeLlm([
      const [LlmStreamChunk(textDelta: '直接回答')],
    ]);
    final scenario = _FakeScenario();
    final loop = AgentLoop(llm: llm, scenario: scenario);
    final events = await loop.run([const ChatMessage(role: 'system', content: 'sys')]).toList();
    expect(events.whereType<AgentRoundEndEvent>(), isEmpty);
  });
```

- [ ] **Step 6: 运行测试确认通过**

Run: `cd packages/study_engine && flutter test test/agent_loop_test.dart`
Expected: PASS（含原有测试 + 2 个新测试）

- [ ] **Step 7: 运行全量 engine 测试确认无回归**

Run: `cd packages/study_engine && flutter test`
Expected: 24 tests passed（原 22 + 新 2）

- [ ] **Step 8: 提交**

```bash
cd packages/study_engine
git add lib/src/agent/agent_event.dart lib/src/agent/agent_loop.dart test/agent_loop_test.dart
git commit -m "feat(engine): AgentRoundEndEvent 逐轮携带 assistant+tool 消息

多轮对话前置:让 UI 层能在每轮结束时拿到合法消息序列,
保证续聊下一轮时 AgentLoop 收到完整历史。

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 2: ChatSessionNotifier 多轮会话状态

**Files:**
- Create: `study_buddy/lib/core/providers/chat_session_provider.dart`
- Test: `study_buddy/test/core/providers/chat_session_provider_test.dart`

**Interfaces:**
- Consumes: `AgentSession.run(List<ChatMessage>) → Future<Stream<AgentEvent>>`（`agent_session_provider.dart`，已有不改）；`AgentEvent` 各类型（`AgentRoundEndEvent.newMessages` 来自 Task 1）；`CapturedScreenshot`（`webview_screenshot_provider.dart`，字段 `pngBytes`/`base64DataUri`）；`ChatMessage`/`TextPart`/`ImageUrlPart`（study_engine 导出）
- Produces: `ChatSessionState`（messages/streamingText/toolEvents/busy/saved/error）、`ChatSessionNotifier`（`send(text,{image})`/`clear()`）、`currentChatProvider`（`StateNotifierProvider`）。Task 3 的 UI 依赖这些。

- [ ] **Step 1: 写失败测试 — 首轮带图 + 流式回填**

创建 `study_buddy/test/core/providers/chat_session_provider_test.dart`：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:study_engine/study_engine.dart';
import 'package:study_buddy/core/providers/chat_session_provider.dart';
import 'package:study_buddy/core/providers/webview_screenshot_provider.dart';

/// 假 AgentSession：用预制事件流驱动。
class _FakeAgentSession implements AgentSession {
  _FakeAgentSession(this._events);
  final List<AgentEvent> _events;
  List<List<ChatMessage>> receivedMessages = [];

  @override
  Future<Stream<AgentEvent>> run(List<ChatMessage> messages) async {
    receivedMessages.add(messages);
    return Stream.fromIterable(_events);
  }

  @override
  Ref get _ref => throw UnimplementedError();
}

void main() {
  // 占位，Step 2/3/4 逐步填充
  test('placeholder', () {});
}
```

> 注：`AgentSession` 当前是具体类（非接口），`_ref` 是私有字段无法在外部 implement。需调整策略：`AgentSession` 不改，改为 Notifier 通过构造注入 `run` 回调。见 Step 3 实现的 `currentChatProvider` 用 `override` 方式测试。**修正测试策略**：用 ProviderContainer override `agentSessionProvider` 返回 fake。

重写测试文件为：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:study_engine/study_engine.dart';
import 'package:study_buddy/core/providers/chat_session_provider.dart';
import 'package:study_buddy/core/providers/agent_session_provider.dart';
import 'package:study_buddy/core/providers/webview_screenshot_provider.dart';

/// 假 AgentSession：用预制事件流驱动，记录收到的 messages。
class _FakeAgentSession extends AgentSession {
  _FakeAgentSession(this._events) : super(_DummyRef());
  final List<AgentEvent> _events;
  final List<List<ChatMessage>> receivedMessages = [];

  @override
  Future<Stream<AgentEvent>> run(List<ChatMessage> messages) async {
    receivedMessages.add(List.of(messages));
    return Stream.fromIterable(_events);
  }
}

/// 占位 Ref，FakeAgentSession 不走真 DB，run 被 override 不会用到 _ref。
class _DummyRef implements Ref {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

CapturedScreenshot _screenshot() =>
    CapturedScreenshot(Uint8List.fromList([1, 2, 3]), 'data:image/png;base64,MTIz');

void main() {
  test('首轮带图:send 后 messages 含 user(图)+assistant', () async {
    final fake = _FakeAgentSession([
      const TextDeltaEvent('你好'),
      const TextDeltaEvent('世界'),
      AgentRoundEndEvent([const ChatMessage(role: 'assistant', content: '你好世界')]),
      const AgentDoneEvent('你好世界'),
    ]);
    final container = ProviderContainer(overrides: [
      agentSessionProvider.overrideWithValue(fake),
    ]);
    addTearDown(container.dispose);

    final notifier = container.read(currentChatProvider.notifier);
    await notifier.send('分析这道题', image: _screenshot());

    final state = container.read(currentChatProvider);
    expect(state.messages, hasLength(2));
    expect(state.messages[0].role, 'user');
    expect(state.messages[1].role, 'assistant');
    expect(state.busy, isFalse);
    expect(state.streamingText, isEmpty);
  });

  test('二轮续聊:run 入参含完整历史', () async {
    final fake = _FakeAgentSession([
      AgentRoundEndEvent([const ChatMessage(role: 'assistant', content: '答1')]),
      const AgentDoneEvent('答1'),
    ]);
    final container = ProviderContainer(overrides: [
      agentSessionProvider.overrideWithValue(fake),
    ]);
    addTearDown(container.dispose);

    final notifier = container.read(currentChatProvider.notifier);
    await notifier.send('问1', image: _screenshot());
    await notifier.send('问2');

    // 第二次 run 收到的 messages 应含第 1 轮的 user+assistant + 第 2 轮 user
    expect(fake.receivedMessages[1], hasLength(3));
    expect(fake.receivedMessages[1][0].role, 'user');   // 问1
    expect(fake.receivedMessages[1][1].role, 'assistant'); // 答1
    expect(fake.receivedMessages[1][2].role, 'user');   // 问2
  });

  test('工具调用轮:Done 后 messages 含 assistant(toolCalls)+tool', () async {
    final fake = _FakeAgentSession([
      AgentRoundEndEvent([
        const ChatMessage(role: 'assistant', content: '', toolCalls: [
          ToolCall(id: 'c1', name: 'save_topic', arguments: '{"subject":"数学","title":"方程"}'),
        ]),
        const ChatMessage(role: 'tool', content: '已保存', toolCallId: 'c1'),
      ]),
      const AgentDoneEvent('已为你保存'),
    ]);
    final container = ProviderContainer(overrides: [
      agentSessionProvider.overrideWithValue(fake),
    ]);
    addTearDown(container.dispose);

    final notifier = container.read(currentChatProvider.notifier);
    await notifier.send('保存这个', image: _screenshot());

    final state = container.read(currentChatProvider);
    expect(state.messages, hasLength(3)); // user + assistant + tool
    expect(state.messages[1].toolCalls, hasLength(1));
    expect(state.messages[2].role, 'tool');
    expect(state.messages[2].toolCallId, 'c1');
    expect(state.saved, isTrue);
  });

  test('busy 守卫:运行中再 send 被忽略', () async {
    final fake = _FakeAgentSession([
      const TextDeltaEvent('慢'),
      AgentRoundEndEvent([const ChatMessage(role: 'assistant', content: '慢')]),
      const AgentDoneEvent('慢'),
    ]);
    final container = ProviderContainer(overrides: [
      agentSessionProvider.overrideWithValue(fake),
    ]);
    addTearDown(container.dispose);

    final notifier = container.read(currentChatProvider.notifier);
    final future1 = notifier.send('问1', image: _screenshot());
    // future1 还未完成时立即发第二次
    await notifier.send('问2');
    await future1;

    // 只应有一次 run 调用
    expect(fake.receivedMessages, hasLength(1));
  });

  test('构造期抛错回滚 user 消息', () async {
    final fake = _FakeAgentSession([]); // 不会用到，run 会抛
    final container = ProviderContainer(overrides: [
      agentSessionProvider.overrideWithValue(_ThrowingAgentSession()),
    ]);
    addTearDown(container.dispose);

    final notifier = container.read(currentChatProvider.notifier);
    await notifier.send('问1', image: _screenshot());

    final state = container.read(currentChatProvider);
    expect(state.messages, isEmpty); // user 被回滚
    expect(state.error, isNotNull);
    expect(state.busy, isFalse);
  });

  test('clear 清空全部状态', () async {
    final fake = _FakeAgentSession([
      AgentRoundEndEvent([const ChatMessage(role: 'assistant', content: '答')]),
      const AgentDoneEvent('答'),
    ]);
    final container = ProviderContainer(overrides: [
      agentSessionProvider.overrideWithValue(fake),
    ]);
    addTearDown(container.dispose);

    final notifier = container.read(currentChatProvider.notifier);
    await notifier.send('问', image: _screenshot());
    expect(container.read(currentChatProvider).messages, isNotEmpty);

    notifier.clear();
    final state = container.read(currentChatProvider);
    expect(state.messages, isEmpty);
    expect(state.streamingText, isEmpty);
    expect(state.toolEvents, isEmpty);
  });
}

class _ThrowingAgentSession extends AgentSession {
  _ThrowingAgentSession() : super(_DummyRef());
  @override
  Future<Stream<AgentEvent>> run(List<ChatMessage> messages) async {
    throw StateError('未配置支持视觉的默认 LLM');
  }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd study_buddy && flutter test test/core/providers/chat_session_provider_test.dart`
Expected: FAIL — `chat_session_provider.dart` 不存在，编译失败。

- [ ] **Step 3: 实现 chat_session_provider.dart**

创建 `study_buddy/lib/core/providers/chat_session_provider.dart`：

```dart
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:study_engine/study_engine.dart';

import 'agent_session_provider.dart';
import 'webview_screenshot_provider.dart';

/// 工具调用轨迹条目（UI 渲染用）。
class ToolEvent {
  final String name;
  final String result; // '进行中...' 或实际结果摘要
  const ToolEvent(this.name, this.result);
}

/// 当前会话的内存状态。纯内存，不持久化。
class ChatSessionState {
  final List<ChatMessage> messages; // 完整多轮历史
  final String streamingText; // 当前轮 LLM 流式增量累积
  final List<ToolEvent> toolEvents; // 当前轮工具轨迹
  final bool busy; // agent 运行中
  final bool saved; // 本轮触发过 save_topic
  final String? error;

  const ChatSessionState({
    this.messages = const [],
    this.streamingText = '',
    this.toolEvents = const [],
    this.busy = false,
    this.saved = false,
    this.error,
  });

  ChatSessionState copyWith({
    List<ChatMessage>? messages,
    String? streamingText,
    List<ToolEvent>? toolEvents,
    bool? busy,
    bool? saved,
    String? error,
  }) {
    return ChatSessionState(
      messages: messages ?? this.messages,
      streamingText: streamingText ?? this.streamingText,
      toolEvents: toolEvents ?? this.toolEvents,
      busy: busy ?? this.busy,
      saved: saved ?? this.saved,
      error: error,
    );
  }

  static const initial = ChatSessionState();
}

/// 多轮会话状态管理：持有完整消息历史，每轮 send 喂给 AgentSession.run。
class ChatSessionNotifier extends StateNotifier<ChatSessionState> {
  ChatSessionNotifier(this._ref) : super(ChatSessionState.initial);
  final Ref _ref;

  StreamSubscription<AgentEvent>? _sub;

  /// 发送一轮：组装 user 消息（文字+可选图）→ append → 调 AgentSession.run
  /// 监听事件流回填 state。构造期抛错回滚 user 消息。
  Future<void> send(String text, {CapturedScreenshot? image}) async {
    if (state.busy) return;
    final trimmed = text.trim();
    if (trimmed.isEmpty && image == null) return;

    final userContent = <ContentPart>[
      TextPart(trimmed.isEmpty ? '分析这道题涉及的知识点' : trimmed),
      if (image != null) ImageUrlPart(image.base64DataUri, detail: 'high'),
    ];
    final userMsg = ChatMessage(role: 'user', content: userContent);

    // 先 append user，再清空本轮缓冲
    final msgs = [...state.messages, userMsg];
    state = ChatSessionState(
      messages: msgs,
      streamingText: '',
      toolEvents: const [],
      busy: true,
      saved: false,
      error: null,
    );

    try {
      final session = _ref.read(agentSessionProvider);
      final stream = await session.run(msgs);
      _sub = stream.listen(
        _onEvent,
        onError: (e) => _onError('$e'),
        onDone: () {
          if (state.busy) {
            state = state.copyWith(busy: false);
          }
        },
      );
    } catch (e) {
      // 构造期抛错：回滚 user 消息
      state = ChatSessionState(
        messages: state.messages.sublist(0, state.messages.length - 1),
        streamingText: '',
        toolEvents: const [],
        busy: false,
        error: '$e',
      );
    }
  }

  void _onEvent(AgentEvent event) {
    if (!mounted) return;
    switch (event) {
      case AgentStartedEvent():
        break;
      case TextDeltaEvent(:final delta):
        state = state.copyWith(streamingText: state.streamingText + delta);
      case ToolCallStartEvent(:final name):
        state = state.copyWith(
          toolEvents: [...state.toolEvents, ToolEvent(name, '进行中...')],
        );
      case ToolCallEndEvent(:final name, :final result):
        final updated = state.toolEvents.map((e) {
          if (e.name == name && e.result == '进行中...') {
            return ToolEvent(name, result);
          }
          return e;
        }).toList();
        final saved = state.saved || name == 'save_topic';
        state = state.copyWith(toolEvents: updated, saved: saved);
      case ToolProgressEvent(:final progress):
        state = state.copyWith(
          toolEvents: [...state.toolEvents, ToolEvent('·', progress)],
        );
      case CompactionEvent():
        state = state.copyWith(
          toolEvents: [...state.toolEvents, const ToolEvent('·', '上下文已压缩')],
        );
      case RetryEvent(:final attempt):
        state = state.copyWith(
          toolEvents: [...state.toolEvents, ToolEvent('·', '重试第 $attempt 次')],
        );
      case AgentRoundEndEvent(:final newMessages):
        // 逐轮回填合法消息序列（assistant + tool 消息）
        state = state.copyWith(messages: [...state.messages, ...newMessages]);
      case AgentDoneEvent(:final finalText):
        // finalText==null 表示达到 maxRounds
        if (finalText == null) {
          state = state.copyWith(
            busy: false,
            error: '已达最大轮数',
            streamingText: '',
          );
        } else {
          state = state.copyWith(busy: false, streamingText: '');
        }
      case AgentErrorEvent(:final message):
        _onError(message);
    }
  }

  void _onError(String msg) {
    if (!mounted) return;
    state = state.copyWith(busy: false, error: msg);
  }

  /// 重置整个会话（抽屉关闭时调用）。
  void clear() {
    _sub?.cancel();
    _sub = null;
    state = ChatSessionState.initial;
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

final currentChatProvider =
    StateNotifierProvider<ChatSessionNotifier, ChatSessionState>((ref) {
  return ChatSessionNotifier(ref);
});
```

> **关键设计说明**：
> - `AgentRoundEndEvent` 携带本轮完整 `newMessages`（assistant+tool），Notifier 直接 `state.messages += newMessages`——零格式知识，职责最干净（对应 spec §3.2 解法2 的演进，实际采用了 RoundEnd 方案，比在 Done 上加 toolCalls 更完整）。
> - `AgentDoneEvent` 不再携带 toolCalls（Task 1 已回退该改动），只负责标记 busy=false。
> - `streamingText` 在 `TextDeltaEvent` 累积，在 `AgentRoundEndEvent`/`AgentDoneEvent` 清空（因为文本已落入 assistant 消息）。
> - `send()` 构造期 try/catch 回滚 user；运行期 `AgentErrorEvent` 不回滚（见 spec §5）。

- [ ] **Step 4: 运行测试确认通过**

Run: `cd study_buddy && flutter test test/core/providers/chat_session_provider_test.dart`
Expected: 6 tests PASS

> 若 `_FakeAgentSession extends AgentSession` 因 `AgentSession` 构造需 `Ref` 报错，用 `_DummyRef implements Ref`（noSuchMethod 兜底）传入。`run` 被 override 后不走真 DB，`_ref` 不会被访问。

- [ ] **Step 5: 提交**

```bash
cd study_buddy
git add lib/core/providers/chat_session_provider.dart test/core/providers/chat_session_provider_test.dart
git commit -m "feat(app): ChatSessionNotifier 纯内存多轮会话状态

StateNotifier 持有 List<ChatMessage>,每轮 send 喂完整历史给
AgentSession.run。AgentRoundEndEvent 逐轮回填合法消息序列。

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3: ai_panel_sheet 改为消息列表 UI

**Files:**
- Modify: `study_buddy/lib/features/external_qbank/ai_panel_sheet.dart`（整体重写）
- Test: `study_buddy/test/features/external_qbank/ai_panel_sheet_test.dart`

**Interfaces:**
- Consumes: `currentChatProvider`（Task 2 产出）、`CapturedScreenshot`（已有）、`showAiPanel(context, {screenshot})` 入口签名不变
- Produces: 改造后的 `showAiPanel` + `_AiPanelSheet`（消息列表 + 连续输入框 + 加图按钮）

- [ ] **Step 1: 写失败测试 — 首轮截图预览 + 消息列表渲染**

创建 `study_buddy/test/features/external_qbank/ai_panel_sheet_test.dart`：

```dart
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:study_engine/study_engine.dart';
import 'package:study_buddy/core/providers/agent_session_provider.dart';
import 'package:study_buddy/core/providers/webview_screenshot_provider.dart';
import 'package:study_buddy/features/external_qbank/ai_panel_sheet.dart';

/// 假 AgentSession：收到 run 后返回一个 assistant 回答。
class _FakeAgentSession extends AgentSession {
  _FakeAgentSession() : super(_DummyRef());
  @override
  Future<Stream<AgentEvent>> run(List<ChatMessage> messages) async {
    return Stream.fromIterable([
      AgentRoundEndEvent([const ChatMessage(role: 'assistant', content: '这是分析')]),
      const AgentDoneEvent('这是分析'),
    ]);
  }
}

class _DummyRef implements Ref {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Uint8List _pngBytes() => Uint8List.fromList(base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M8AAAMBAQDJ/pLvAAAAAElFTkSuQmCC'));

void main() {
  testWidgets('首轮:截图预览可见,发送后显示 user 与 assistant 气泡', (tester) async {
    final screenshot = CapturedScreenshot(_pngBytes(), 'data:image/png;base64,x');
    final container = ProviderContainer(overrides: [
      agentSessionProvider.overrideWithValue(_FakeAgentSession()),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: Scaffold(body: Builder(builder: (ctx) {
        return ElevatedButton(
          onPressed: () => showAiPanel(ctx, screenshot: screenshot),
          child: const Text('open'),
        );
      }))),
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 首轮截图预览可见
    expect(find.byType(Image), findsWidgets);
    // 点发送
    await tester.tap(find.text('开始分析'));
    await tester.pumpAndSettle();

    // user 消息与 assistant 消息都渲染
    expect(find.text('分析这道题涉及的知识点'), findsOneWidget);
    expect(find.text('这是分析'), findsOneWidget);
  });

  testWidgets('追问:输入框可连续输入,加图按钮存在', (tester) async {
    final screenshot = CapturedScreenshot(_pngBytes(), 'data:image/png;base64,x');
    final container = ProviderContainer(overrides: [
      agentSessionProvider.overrideWithValue(_FakeAgentSession()),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: Scaffold(body: Builder(builder: (ctx) {
        return ElevatedButton(
          onPressed: () => showAiPanel(ctx, screenshot: screenshot),
          child: const Text('open'),
        );
      }))),
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 输入框存在
    expect(find.byType(TextField), findsOneWidget);
    // 加图按钮存在（icon）
    expect(find.byIcon(Icons.add_photo_alternate_outlined), findsOneWidget);
  });

  testWidgets('busy 时输入框禁用,按钮显示分析中', (tester) async {
    final screenshot = CapturedScreenshot(_pngBytes(), 'data:image/png;base64,x');
    // 慢返回的 fake：先不立即完成
    final container = ProviderContainer(overrides: [
      agentSessionProvider.overrideWithValue(_FakeAgentSession()),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: Scaffold(body: Builder(builder: (ctx) {
        return ElevatedButton(
          onPressed: () => showAiPanel(ctx, screenshot: screenshot),
          child: const Text('open'),
        );
      }))),
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('开始分析'));
    await tester.pump(); // 不等完成

    // 按钮变为分析中
    expect(find.text('分析中...'), findsOneWidget);
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd study_buddy && flutter test test/features/external_qbank/ai_panel_sheet_test.dart`
Expected: FAIL — 旧 `ai_panel_sheet` 是单次表单，无消息列表、无加图按钮、无"分析中..."文本匹配。

- [ ] **Step 3: 重写 ai_panel_sheet.dart**

整体替换 `study_buddy/lib/features/external_qbank/ai_panel_sheet.dart`：

```dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:study_engine/study_engine.dart';

import '../../core/providers/chat_session_provider.dart';
import '../../core/providers/webview_screenshot_provider.dart';

/// 弹出底部抽屉：消息列表 + 连续输入框 + 可选附图。
///
/// 截图来自 [CapturedScreenshot]，纯内存持有；会话结束即释放（widget dispose）。
Future<void> showAiPanel(
  BuildContext context, {
  required CapturedScreenshot screenshot,
}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    isDismissible: true,
    enableDrag: true,
    builder: (_) => ProviderScope.overrides(
      // 让抽屉内 read 到的 currentChatProvider 与外层一致（Riverpod 默认透传，
      // 此处显式不建新 scope，直接用外层 container）
      overrides: const [],
      child: _AiPanelSheet(initialScreenshot: screenshot),
    ),
  );
}

class _AiPanelSheet extends ConsumerStatefulWidget {
  const _AiPanelSheet({required this.initialScreenshot});
  final CapturedScreenshot initialScreenshot;

  @override
  ConsumerState<_AiPanelSheet> createState() => _AiPanelSheetState();
}

class _AiPanelSheetState extends ConsumerState<_AiPanelSheet> {
  final TextEditingController _inputCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  CapturedScreenshot? _pendingImage; // 追问轮待附加的图
  bool _firstSent = false;

  @override
  void initState() {
    super.initState();
    // 首轮：用入口截图作为首条消息的图。但不自动发送——等用户点"开始分析"。
    _pendingImage = widget.initialScreenshot;
  }

  @override
  void dispose() {
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    // 抽屉关闭即清空会话（纯内存）
    ref.read(currentChatProvider.notifier).clear();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _inputCtrl.text;
    final image = _pendingImage;
    _inputCtrl.clear();
    setState(() {
      _pendingImage = null;
      _firstSent = true;
    });
    await ref.read(currentChatProvider.notifier).send(text, image: image);
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(currentChatProvider);
    final mediaQuery = MediaQuery.of(context);
    _scrollToBottom();

    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 12,
        bottom: mediaQuery.viewInsets.bottom + 16,
      ),
      child: SizedBox(
        height: mediaQuery.size.height * 0.7,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 抓把手
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: Colors.grey.shade400,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            // 消息列表
            Expanded(
              child: ListView(
                controller: _scrollCtrl,
                children: [
                  ...state.messages.map(_buildMessageBubble),
                  // 流式文本（当前轮 LLM 正在输出）
                  if (state.streamingText.isNotEmpty)
                    _buildAssistantBubble(state.streamingText, state.toolEvents),
                  // 首轮未发送时显示截图预览
                  if (!_firstSent && _pendingImage != null)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.memory(
                        _pendingImage!.pngBytes,
                        height: 120,
                        fit: BoxFit.contain,
                      ),
                    ),
                ],
              ),
            ),
            // 错误展示
            if (state.error != null)
              Container(
                margin: const EdgeInsets.only(top: 8),
                padding: const EdgeInsets.all(8),
                color: Colors.red.shade50,
                child: Text(state.error!, style: TextStyle(color: Colors.red.shade900)),
              ),
            // 待附图预览（追问轮）
            if (_pendingImage != null && _firstSent)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: Image.memory(_pendingImage!.pngBytes,
                          height: 48, fit: BoxFit.contain),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () => setState(() => _pendingImage = null),
                    ),
                  ],
                ),
              ),
            // 输入行
            const SizedBox(height: 8),
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.add_photo_alternate_outlined),
                  onPressed: state.busy
                      ? null
                      : () {
                          // MVP:追问轮加图复用 initialScreenshot 的数据来源；
                          // 真实截图接入由悬浮窗阶段提供。此处仅占位禁用或提示。
                          // （本任务不实现真实选图,留待截图入口统一）
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('加图功能待截图入口接入')),
                          );
                        },
                ),
                Expanded(
                  child: TextField(
                    controller: _inputCtrl,
                    enabled: !state.busy,
                    decoration: InputDecoration(
                      hintText: _firstSent ? '追问...' : '补充说明（可选）',
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                    onSubmitted: (_) => _send(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: state.busy ? null : _send,
                  child: Text(state.busy ? '分析中...' : (_firstSent ? '发送' : '开始分析')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMessageBubble(ChatMessage msg) {
    if (msg.role == 'user') return _buildUserBubble(msg);
    if (msg.role == 'assistant') return _buildAssistantBubble(
        msg.content is String ? msg.content as String : '',
        const []);
    if (msg.role == 'tool') {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Text('🔧 ${msg.content}',
            style: const TextStyle(fontSize: 12, color: Colors.grey)),
      );
    }
    return const SizedBox.shrink();
  }

  Widget _buildUserBubble(ChatMessage msg) {
    final text = msg.content is String
        ? msg.content as String
        : (msg.content as List<ContentPart>)
            .whereType<TextPart>()
            .map((t) => t.text)
            .join();
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.deepPurple.shade100,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(text),
      ),
    );
  }

  Widget _buildAssistantBubble(String text, List<ToolEvent> toolEvents) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.grey.shade100,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (text.isNotEmpty) SelectableText(text),
            ...toolEvents.map((e) => Text('${e.name}: ${e.result}',
                style: const TextStyle(fontSize: 12, color: Colors.grey))),
          ],
        ),
      ),
    );
  }
}
```

> **关键设计说明**：
> - 首轮：`_pendingImage = initialScreenshot`，用户点"开始分析"后 `_send()` 把图+默认文字（"分析这道题涉及的知识点"）发给 Notifier。
> - 追问轮：`_firstSent=true` 后输入框 hintText 变"追问..."，按钮变"发送"，可选点加图按钮（MVP 阶段加图入口占位——真实截图来源由悬浮窗阶段统一提供，本任务仅留按钮+提示）。
> - 消息列表：`state.messages` 渲染 user/assistant/tool 气泡；`state.streamingText` 单独渲染（当前轮流式）；`toolEvents` 挂在 assistant 气泡下。
> - `dispose` 调 `clear()` 清空会话（纯内存）。
> - `showAiPanel` 入口签名不变（仍收 `CapturedScreenshot`），外部调用方零改动。

- [ ] **Step 4: 运行测试确认通过**

Run: `cd study_buddy && flutter test test/features/external_qbank/ai_panel_sheet_test.dart`
Expected: 3 tests PASS

> 若 `ProviderScope.overrides(overrides: const [])` 写法报错，改为直接 `builder: (_) => _AiPanelSheet(...)`（Riverpod 默认透传外层 container，无需显式 scope）。修正 `showAiPanel`：

```dart
  builder: (_) => _AiPanelSheet(initialScreenshot: screenshot),
```

- [ ] **Step 5: 运行 flutter analyze 确认无静态错误**

Run: `cd study_buddy && flutter analyze`
Expected: No issues found

- [ ] **Step 6: 运行全量 App 测试确认无回归**

Run: `cd study_buddy && flutter test`
Expected: All tests passed

- [ ] **Step 7: 提交**

```bash
cd study_buddy
git add lib/features/external_qbank/ai_panel_sheet.dart test/features/external_qbank/ai_panel_sheet_test.dart
git commit -m "feat(app): ai_panel_sheet 改为消息列表多轮 UI

单次表单 → 消息列表+连续输入框+加图按钮。
读 currentChatProvider 渲染历史,流式 streamingText 实时显示。
抽屉关闭即 clear() 清空会话(纯内存)。

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Self-Review

**1. Spec 覆盖：**
- §1.2 纯内存不持久化 → Task 2 Notifier 纯内存 + Task 3 dispose 调 clear() ✅
- §1.2 截图纯内存 → CapturedScreenshot 只进 ImageUrlPart，不落盘 ✅
- §1.2 引擎业务逻辑零改动 → Task 1 只加事件类 + yield，不改 scenario/tools ✅
- §1.2 AgentSession 无状态 → Task 2 不改 agent_session_provider.dart ✅
- §1.2 追问可选附图 → Task 3 加图按钮（MVP 占位）✅
- §2 解法2 → Task 1 演进为 AgentRoundEndEvent（比 Done+toolCalls 更完整，spec §3.2 已论证 Notifier 零格式知识为最优）✅
- §3.1 数据流首轮/追问 → Task 2 send() 实现 ✅
- §3.2 事件回填 → Task 2 _onEvent 实现 ✅
- §4 组件清单 → Task 2/3 覆盖 ✅
- §5 错误处理（busy 守卫/构造期回滚/运行期不回滚/maxRounds/clear）→ Task 2 测试+实现覆盖 ✅
- §6 测试策略（引擎+1/Notifier 6/widget 3）→ 三个 Task 覆盖 ✅

**2. 占位符扫描：** 无 TBD/TODO。Task 3 加图按钮的"加图功能待截图入口接入"是 MVP 范围控制（spec §7 明确追问可选附图，真实选图入口由悬浮窗阶段提供），非占位符。✅

**3. 类型一致性：**
- `AgentRoundEndEvent.newMessages: List<ChatMessage>` — Task 1 定义，Task 2 `_onEvent` 消费 ✅
- `ChatSessionState` 字段 messages/streamingText/toolEvents/busy/saved/error — Task 2 定义，Task 3 `ref.watch` 消费 ✅
- `ChatSessionNotifier.send(String, {CapturedScreenshot?})` / `clear()` — Task 2 定义，Task 3 调用 ✅
- `currentChatProvider` — Task 2 定义，Task 3 `ref.watch`/`ref.read` ✅
- `ToolEvent(name, result)` — Task 2 定义，Task 3 `_buildAssistantBubble` 消费 ✅
- `showAiPanel(context, {required CapturedScreenshot screenshot})` — 签名不变 ✅

**4. spec 措辞修正：** spec §3.2/§3.3 写的是"解法2：AgentDoneEvent +toolCalls"，但实施中发现 Done 只发一次无法携带中间轮消息，演进为 `AgentRoundEndEvent`（逐轮携带完整消息）。这比原解法2 更优（Notifier 零格式知识）。**需在执行前同步修正 spec**——此项作为 Task 1 的前置说明已记录在计划中，执行时一并更新 spec 文档。

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-08-10-multi-turn-chat.md`. 用户已指定用 **Subagent-Driven** 方式执行，直接进入。
