import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:study_buddy/core/providers/agent_session_provider.dart';
import 'package:study_buddy/core/providers/chat_session_provider.dart';
import 'package:study_buddy/core/providers/webview_screenshot_provider.dart';
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

  @override
  Future<Stream<AgentEvent>> run(List<ChatMessage> messages) async {
    receivedMessages.add(List.of(messages));
    return Stream.fromIterable(_events);
  }
}

CapturedScreenshot _screenshot() =>
    CapturedScreenshot(Uint8List.fromList([1, 2, 3]), 'data:image/png;base64,MTIz');

void main() {
  test('首轮带图:send 后 messages 含 user(图)+assistant', () async {
    final events = <AgentEvent>[
      TextDeltaEvent('你好'),
      TextDeltaEvent('世界'),
      AgentRoundEndEvent([const ChatMessage(role: 'assistant', content: '你好世界')]),
      AgentDoneEvent('你好世界'),
    ];
    final container = ProviderContainer(overrides: [
      agentSessionProvider.overrideWith((ref) => _FakeAgentSession(ref, events)),
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
    final events = <AgentEvent>[
      AgentRoundEndEvent([const ChatMessage(role: 'assistant', content: '答1')]),
      AgentDoneEvent('答1'),
    ];
    _FakeAgentSession? captured;
    final container = ProviderContainer(overrides: [
      agentSessionProvider.overrideWith((ref) {
        return captured = _FakeAgentSession(ref, events);
      }),
    ]);
    addTearDown(container.dispose);

    final notifier = container.read(currentChatProvider.notifier);
    await notifier.send('问1', image: _screenshot());
    await notifier.send('问2');

    // 第二次 run 收到的 messages 应含第 1 轮的 user+assistant + 第 2 轮 user
    expect(captured!.receivedMessages[1], hasLength(3));
    expect(captured!.receivedMessages[1][0].role, 'user'); // 问1
    expect(captured!.receivedMessages[1][1].role, 'assistant'); // 答1
    expect(captured!.receivedMessages[1][2].role, 'user'); // 问2
  });

  test('工具调用轮:Done 后 messages 含 assistant(toolCalls)+tool', () async {
    final events = <AgentEvent>[
      AgentRoundEndEvent([
        const ChatMessage(role: 'assistant', content: '', toolCalls: [
          ToolCall(id: 'c1', name: 'save_topic', arguments: '{"subject":"数学","title":"方程"}'),
        ]),
        const ChatMessage(role: 'tool', content: '已保存', toolCallId: 'c1'),
      ]),
      AgentDoneEvent('已为你保存'),
    ];
    final container = ProviderContainer(overrides: [
      agentSessionProvider.overrideWith((ref) => _FakeAgentSession(ref, events)),
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

  test('多轮工具调用:每轮 streamingText 独立,不跨轮累积', () async {
    final events = <AgentEvent>[
      // 第 1 轮：工具调用
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
      AgentRoundEndEvent([const ChatMessage(role: 'assistant', content: '总结完毕')]),
      AgentDoneEvent('总结完毕'),
    ];
    final container = ProviderContainer(overrides: [
      agentSessionProvider.overrideWith((ref) => _FakeAgentSession(ref, events)),
    ]);
    addTearDown(container.dispose);

    final notifier = container.read(currentChatProvider.notifier);
    await notifier.send('保存并总结', image: _screenshot());

    final state = container.read(currentChatProvider);
    // 关键：streamingText 不应含第 1 轮残留（AgentRoundEndEvent 已清空）
    expect(state.streamingText, isEmpty);
    // 第 2 轮的 assistant 消息已落入 messages
    expect(
      state.messages.any((m) =>
          m.role == 'assistant' && (m.content as String).contains('总结完毕')),
      isTrue,
    );
  });

  test('busy 守卫:运行中再 send 被忽略', () async {
    final events = <AgentEvent>[
      TextDeltaEvent('慢'),
      AgentRoundEndEvent([const ChatMessage(role: 'assistant', content: '慢')]),
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
    final events = <AgentEvent>[
      AgentRoundEndEvent([const ChatMessage(role: 'assistant', content: '答')]),
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
}

class _ThrowingAgentSession extends AgentSession {
  _ThrowingAgentSession(super.ref);
  @override
  Future<Stream<AgentEvent>> run(List<ChatMessage> messages) async {
    throw StateError('未配置支持视觉的默认 LLM');
  }
}
