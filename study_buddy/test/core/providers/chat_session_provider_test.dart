import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:study_buddy/core/providers/agent_session_provider.dart';
import 'package:study_buddy/core/providers/chat_session_provider.dart';
import 'package:study_buddy/core/providers/captured_image.dart';
import 'package:study_engine/study_engine.dart';

/// 假 AgentSession：用预制事件流驱动，记录收到的 messages。
///
/// 注：Riverpod 3.x 中 `Ref` 为 sealed 类，外部库无法 `implements Ref`。
/// 因此 fake 通过 `overrideWith((ref) => _FakeAgentSession(ref, ...))` 注入，
/// 由 Riverpod 把真实 Ref 传进来，再交给 `super(ref)`，避免 _DummyRef。
class _FakeAgentSession extends AgentSession {
  _FakeAgentSession(super.ref, this._events);
  final List<AgentEvent> _events;
  final List<List<ChatMessage>> receivedMessages = [];
  /// 每次 run 收到的 topicId（教学入口参数），用于断言 startTopicTeaching 透传。
  final List<int?> receivedTopicIds = [];
  AgentSessionHandle? lastHandle;

  @override
  Future<AgentSessionHandle> run(List<ChatMessage> messages, {int? chatSessionId, int? planId, DateTime? today, int? topicId}) async {
    receivedMessages.add(List.of(messages));
    receivedTopicIds.add(topicId);
    final handle = AgentSessionHandle(stream: Stream.fromIterable(_events));
    lastHandle = handle;
    return handle;
  }
}

CapturedScreenshot _screenshot() =>
    CapturedScreenshot(Uint8List.fromList([1, 2, 3]), 'data:image/png;base64,MTIz');

void main() {
  // 事件序列必须严格遵循引擎真实契约（见 agent_loop.dart）：
  // - 纯文本轮：TextDeltaEvent* + AgentDoneEvent(finalText)，NO RoundEnd
  // - 工具调用轮：ToolCallStart/End + AgentRoundEndEvent([assistant(toolCalls), tool, ...])
  //   之后可能续一轮纯文本轮（TextDelta* + AgentDoneEvent）
  // - AgentDoneEvent(null) 仅表示达 maxRounds

  test('首轮带图:纯文本轮,Done 携带 finalText 落入 messages', () async {
    // 纯文本轮：TextDelta + Done（无 RoundEnd）—— 契约由 agent_loop.dart 保证
    final events = <AgentEvent>[
      TextDeltaEvent('你好'),
      TextDeltaEvent('世界'),
      AgentDoneEvent('你好世界'),
    ];
    final container = ProviderContainer(overrides: [
      agentSessionProvider.overrideWith((ref) => _FakeAgentSession(ref, events)),
    ]);
    addTearDown(container.dispose);

    final notifier = container.read(currentChatProvider.notifier);
    await notifier.send('分析这道题', image: _screenshot());

    final state = container.read(currentChatProvider);
    // C1 修复后：assistant 最终文本经 Done 追加到 messages
    expect(state.messages, hasLength(2)); // user + assistant(最终文本)
    expect(state.messages[0].role, 'user');
    expect(state.messages[1].role, 'assistant');
    expect(state.messages[1].content, '你好世界');
    expect(state.busy, isFalse);
    expect(state.streamingText, isEmpty);
  });

  test('二轮续聊:第二次 run 入参含完整历史(含上轮 assistant)', () async {
    // 两次纯文本轮，每次都 TextDelta + Done（无 RoundEnd）
    _FakeAgentSession? captured;
    final container = ProviderContainer(overrides: [
      agentSessionProvider.overrideWith((ref) {
        // 两次 run 用同一组事件即可（各自独立 send）
        return captured = _FakeAgentSession(
          ref,
          [TextDeltaEvent('答'), AgentDoneEvent('答')],
        );
      }),
    ]);
    addTearDown(container.dispose);

    final notifier = container.read(currentChatProvider.notifier);
    await notifier.send('问1', image: _screenshot());
    await notifier.send('问2');

    // 第二次 run 收到的 messages 应含第 1 轮 user+assistant + 第 2 轮 user
    expect(captured!.receivedMessages[1], hasLength(3));
    expect(captured!.receivedMessages[1][0].role, 'user'); // 问1
    expect(captured!.receivedMessages[1][1].role, 'assistant'); // 答1
    expect(captured!.receivedMessages[1][1].content, '答');
    expect(captured!.receivedMessages[1][2].role, 'user'); // 问2
  });

  test('工具调用轮:RoundEnd 后续纯文本轮,Done 落最终回答', () async {
    // 工具调用轮：RoundEnd([assistant(toolCalls), tool])
    // 续一轮纯文本轮：TextDelta + AgentDoneEvent(finalText)
    final events = <AgentEvent>[
      AgentRoundEndEvent([
        const ChatMessage(role: 'assistant', content: '', toolCalls: [
          ToolCall(id: 'c1', name: 'save_topic', arguments: '{"subject":"数学","title":"方程"}'),
        ]),
        const ChatMessage(role: 'tool', content: '已保存', toolCallId: 'c1'),
      ]),
      TextDeltaEvent('已'),
      TextDeltaEvent('为你保存'),
      AgentDoneEvent('已为你保存'),
    ];
    final container = ProviderContainer(overrides: [
      agentSessionProvider.overrideWith((ref) => _FakeAgentSession(ref, events)),
    ]);
    addTearDown(container.dispose);

    final notifier = container.read(currentChatProvider.notifier);
    await notifier.send('保存这个', image: _screenshot());

    final state = container.read(currentChatProvider);
    // messages = [user, assistant(toolCalls), tool, assistant(finalText)]
    expect(state.messages, hasLength(4));
    expect(state.messages[0].role, 'user');
    expect(state.messages[1].role, 'assistant');
    expect(state.messages[1].toolCalls, hasLength(1));
    expect(state.messages[1].toolCalls!.single.id, 'c1');
    expect(state.messages[2].role, 'tool');
    // tool 消息的 toolCallId 必须与 assistant 的 toolCall id 配对
    expect(state.messages[2].toolCallId, 'c1');
    expect(state.messages[3].role, 'assistant');
    expect(state.messages[3].content, '已为你保存');
    expect(state.busy, isFalse);
    expect(state.streamingText, isEmpty);
  });

  test('多轮工具调用:每轮 streamingText 独立,不跨轮累积', () async {
    // 第 1 轮：工具调用轮，先 TextDelta 后 RoundEnd（RoundEnd 清空 streamingText）
    // 第 2 轮：纯文本轮，TextDelta* + AgentDoneEvent（Done 落最终回答并清空 streamingText）
    final events = <AgentEvent>[
      TextDeltaEvent('正在保存'),
      AgentRoundEndEvent([
        const ChatMessage(role: 'assistant', content: '正在保存', toolCalls: [
          ToolCall(id: 'c1', name: 'save_topic', arguments: '{"subject":"数学","title":"方程"}'),
        ]),
        const ChatMessage(role: 'tool', content: '已保存', toolCallId: 'c1'),
      ]),
      // 第 2 轮：LLM 看到工具结果后总结
      TextDeltaEvent('总结'),
      TextDeltaEvent('完毕'),
      AgentDoneEvent('总结完毕'),
    ];
    final container = ProviderContainer(overrides: [
      agentSessionProvider.overrideWith((ref) => _FakeAgentSession(ref, events)),
    ]);
    addTearDown(container.dispose);

    final notifier = container.read(currentChatProvider.notifier);
    await notifier.send('保存并总结', image: _screenshot());

    final state = container.read(currentChatProvider);
    // F1 — streamingText 不应跨轮累积（RoundEnd 与 Done 都会清空）
    expect(state.streamingText, isEmpty);
    // C1 — 最终回答经 Done 落入 messages
    expect(
      state.messages.any((m) =>
          m.role == 'assistant' && (m.content as String).contains('总结完毕')),
      isTrue,
    );
    // 工具调用轮的 assistant(toolCalls) 与 tool 也在 messages
    expect(state.messages.any((m) => m.role == 'tool' && m.toolCallId == 'c1'), isTrue);
    expect(
      state.messages.any((m) =>
          m.role == 'assistant' && m.toolCalls != null && m.toolCalls!.isNotEmpty),
      isTrue,
    );
  });

  test('busy 守卫:运行中再 send 被忽略', () async {
    // 纯文本轮：TextDelta + Done（无 RoundEnd）
    final events = <AgentEvent>[
      TextDeltaEvent('慢'),
      AgentDoneEvent('慢'),
    ];
    _FakeAgentSession? captured;
    final container = ProviderContainer(overrides: [
      agentSessionProvider.overrideWith((ref) {
        return captured = _FakeAgentSession(ref, events);
      }),
    ]);
    addTearDown(container.dispose);

    final notifier = container.read(currentChatProvider.notifier);
    final future1 = notifier.send('问1', image: _screenshot());
    // future1 还未完成时立即发第二次
    await notifier.send('问2');
    await future1;

    // 只应有一次 run 调用
    expect(captured!.receivedMessages, hasLength(1));
  });

  test('构造期抛错回滚 user 消息', () async {
    final container = ProviderContainer(overrides: [
      agentSessionProvider.overrideWith((ref) => _ThrowingAgentSession(ref)),
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
    // 纯文本轮：TextDelta + Done（无 RoundEnd）
    final events = <AgentEvent>[
      TextDeltaEvent('答'),
      AgentDoneEvent('答'),
    ];
    final container = ProviderContainer(overrides: [
      agentSessionProvider.overrideWith((ref) => _FakeAgentSession(ref, events)),
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

  test('startTopicTeaching: 清空旧会话 + 发开场消息 + run 收到 topicId', () async {
    final events = <AgentEvent>[
      TextDeltaEvent('开场'),
      AgentDoneEvent('开场'),
    ];
    _FakeAgentSession? captured;
    final container = ProviderContainer(overrides: [
      agentSessionProvider.overrideWith((ref) {
        return captured = _FakeAgentSession(ref, events);
      }),
    ]);
    addTearDown(container.dispose);

    final notifier = container.read(currentChatProvider.notifier);
    // 先积累一轮旧会话（普通模式，topicId 应为 null）
    await notifier.send('旧问题', image: _screenshot());
    expect(container.read(currentChatProvider).messages, isNotEmpty);

    // 教学启动：清旧会话 → 记录 topic → 发开场消息触发 AI 开场
    notifier.startTopicTeaching(42);
    // 开场 send 是 unawaited 异步，等事件流（Stream.fromIterable）走完
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final state = container.read(currentChatProvider);
    // 旧会话被清空，只剩开场 user + assistant 回复
    expect(state.messages, hasLength(2));
    expect(state.messages[0].role, 'user');
    expect(state.messages[1].role, 'assistant');
    expect(state.messages[1].content, '开场');
    expect(state.busy, isFalse);
    // 开场 user 消息是教学指令（含「场景」），且不以用户气泡语义泄漏
    final userContent = state.messages[0].content as List<ContentPart>;
    final userText = userContent.whereType<TextPart>().map((p) => p.text).join();
    expect(userText, contains('场景'));
    // run 透传 topicId：旧轮为 null，教学轮为 42
    expect(captured!.receivedTopicIds, [null, 42]);
  });

  test('send 运行中 clear:挂起的 send future 必须返回(不永久挂起)', () async {
    // 用 controller 制造一个不会自动结束的流，模拟 agent 仍在跑时用户关闭抽屉。
    final container = ProviderContainer(overrides: [
      agentSessionProvider.overrideWith((ref) => _HangingAgentSession(ref)),
    ]);
    addTearDown(container.dispose);

    final notifier = container.read(currentChatProvider.notifier);
    final sendFuture = notifier.send('问', image: _screenshot());
    // 等一拍让流订阅建立、send 进入 await done.future
    await Future.delayed(const Duration(milliseconds: 10));
    expect(container.read(currentChatProvider).busy, isTrue);

    // 中途 clear：取消订阅不触发 onDone，必须靠 clear 主动 complete done
    notifier.clear();

    // send future 应在合理时间内完成，而非永久挂起
    await sendFuture.timeout(const Duration(seconds: 1));
    expect(container.read(currentChatProvider).messages, isEmpty);
  });

  testWidgets('App detached 触发当前会话清空', (tester) async {
    // 单元环境没有 app.dart 的 observer，用一个最小 probe 复现 detached 接线契约：
    // didChangeAppLifecycleState(detached) → currentChatProvider.notifier.clear()。
    final events = <AgentEvent>[
      TextDeltaEvent('答'),
      AgentDoneEvent('答'),
    ];
    final container = ProviderContainer(overrides: [
      agentSessionProvider.overrideWith((ref) => _FakeAgentSession(ref, events)),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: _DetachedClearProbe(
          onDetached: () =>
              container.read(currentChatProvider.notifier).clear(),
        ),
      ),
    ));

    // 先 send 一轮让 messages 非空
    await container.read(currentChatProvider.notifier).send('问', image: _screenshot());
    await tester.pump();
    expect(container.read(currentChatProvider).messages, isNotEmpty);

    // 模拟系统分发 detached 事件 → probe 调 clear
    final binding = tester.binding;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);
    await tester.pump();

    expect(container.read(currentChatProvider).messages, isEmpty);
  });

  test('ask_user:pendingAsk 在 Requested 后置位,respondToAsk 回灌并清空', () async {
    // 事件序列：ask_user 挂起(不自动结束) → UI 调 respondToAsk → Answered → RoundEnd+Done。
    // 用 controller 控制流不自动放完，模拟 agent 真的挂起等用户。
    final ctrl = StreamController<AgentEvent>();
    _FakeAgentSession? captured;
    final container = ProviderContainer(overrides: [
      agentSessionProvider.overrideWith((ref) {
        captured = _FakeAgentSession(ref, const []);
        return _DelayedSession(ref, captured!, ctrl);
      }),
    ]);
    addTearDown(container.dispose);

    final notifier = container.read(currentChatProvider.notifier);
    final sendFuture = notifier.send('帮我创建计划');
    // 事件先放 AskUserRequested（agent 挂起等用户）
    ctrl.add(AskUserRequestedEvent(AskUserRequest(
      question: '选哪个学科？',
      toolCallId: 'ask-1',
      options: [
        AskUserOption(label: '数学', value: 'math'),
        AskUserOption(label: '英语', value: 'eng'),
      ],
    )));
    await Future.delayed(const Duration(milliseconds: 10));

    // agent 挂起期间：pendingAsk 置位、busy 保持 true（阻断重复 send）
    var state = container.read(currentChatProvider);
    expect(state.pendingAsk, isNotNull);
    expect(state.pendingAsk!.question, '选哪个学科？');
    expect(state.pendingAsk!.options.map((o) => o.value), ['math', 'eng']);
    expect(state.busy, isTrue);

    // UI 调 respondToAsk 喂答案 → pendingAsk 清空
    notifier.respondToAsk('math');
    state = container.read(currentChatProvider);
    expect(state.pendingAsk, isNull);

    // 后续事件：agent 拿到答案继续 → Answered → RoundEnd → Done
    ctrl.add(AskUserAnsweredEvent('ask-1', 'math'));
    ctrl.add(ToolCallEndEvent('ask_user', 'math', 'ask-1'));
    ctrl.add(AgentRoundEndEvent([
      const ChatMessage(role: 'assistant', content: '', toolCalls: [
        ToolCall(id: 'ask-1', name: 'ask_user', arguments: '{"question":"选哪个学科？"}'),
      ]),
      const ChatMessage(role: 'tool', content: 'math', toolCallId: 'ask-1'),
    ]));
    ctrl.add(TextDeltaEvent('已确认'));
    ctrl.add(AgentDoneEvent('已确认'));
    await ctrl.close();
    await sendFuture;

    state = container.read(currentChatProvider);
    expect(state.busy, isFalse);
    expect(state.messages.any((m) => m.role == 'tool' && m.toolCallId == 'ask-1'), isTrue);
  });
}

/// 延迟包装：让 fake 用外部 controller 提供的流（不自动放完）。
class _DelayedSession extends AgentSession {
  _DelayedSession(super.ref, this._inner, this._ctrl);
  final _FakeAgentSession _inner;
  final StreamController<AgentEvent> _ctrl;
  @override
  Future<AgentSessionHandle> run(List<ChatMessage> messages, {int? chatSessionId, int? planId, DateTime? today, int? topicId}) async {
    _inner.receivedMessages.add(List.of(messages));
    final handle = AgentSessionHandle(stream: _ctrl.stream);
    _inner.lastHandle = handle;
    return handle;
  }
}

class _ThrowingAgentSession extends AgentSession {
  _ThrowingAgentSession(super.ref);
  @override
  Future<AgentSessionHandle> run(List<ChatMessage> messages, {int? chatSessionId, int? planId, DateTime? today, int? topicId}) async {
    throw StateError('未配置支持视觉的默认 LLM');
  }
}

/// 制造永不自动结束的流：模拟 agent 长时间运行（如等待 LLM 流式响应），
/// 供 clear/dispose 中途打断场景测试。controller 不 close，onDone 不触发。
class _HangingAgentSession extends AgentSession {
  _HangingAgentSession(super.ref);
  @override
  Future<AgentSessionHandle> run(List<ChatMessage> messages, {int? chatSessionId, int? planId, DateTime? today, int? topicId}) async {
    final ctrl = StreamController<AgentEvent>();
    // 不 emit、不 close —— 流保持打开，模拟 agent 正在跑
    return AgentSessionHandle(stream: ctrl.stream);
  }
}

/// 最小 WidgetsBindingObserver：detached 触发 onDetached 回调。
///
/// 复现 `app.dart` 的 detached 接线契约（detached → clear），不依赖整个 App 树。
class _DetachedClearProbe extends StatefulWidget {
  const _DetachedClearProbe({required this.onDetached});
  final VoidCallback onDetached;
  @override
  State<_DetachedClearProbe> createState() => _DetachedClearProbeState();
}

class _DetachedClearProbeState extends State<_DetachedClearProbe>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) widget.onDetached();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
