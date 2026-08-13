import 'package:flutter_test/flutter_test.dart';
import 'package:study_buddy/core/providers/chat_session_provider.dart';
import 'package:study_buddy/core/providers/chat_session_reducer.dart';
import 'package:study_engine/study_engine.dart';

/// chatSessionReducer 纯函数测试：事件 → 状态变更（不含任何副作用）。
void main() {
  test('TextDeltaEvent 累积 streamingText', () {
    final s = chatSessionReducer(
        ChatSessionState.initial, TextDeltaEvent('你'));
    final s2 = chatSessionReducer(s, TextDeltaEvent('好'));
    expect(s2.streamingText, '你好');
    expect(s2.messages, isEmpty);
  });

  test('AgentRoundEndEvent 追加 assistant+tool 并清空 streamingText', () {
    final s0 = ChatSessionState.initial.copyWith(streamingText: '残留');
    final s = chatSessionReducer(s0, AgentRoundEndEvent([
      const ChatMessage(role: 'assistant', content: '', toolCalls: [
        ToolCall(id: 'c1', name: 'save_topic', arguments: '{}'),
      ]),
      const ChatMessage(role: 'tool', content: 'ok', toolCallId: 'c1'),
    ]));
    expect(s.messages, hasLength(2));
    expect(s.messages[0].toolCalls, hasLength(1));
    expect(s.messages[1].toolCallId, 'c1');
    expect(s.streamingText, isEmpty);
  });

  test('AgentDoneEvent(finalText) 追加 assistant + busy=false', () {
    final s = chatSessionReducer(
        ChatSessionState.initial.copyWith(busy: true),
        AgentDoneEvent('最终回答'));
    expect(s.messages, hasLength(1));
    expect(s.messages.single.role, 'assistant');
    expect(s.messages.single.content, '最终回答');
    expect(s.busy, isFalse);
    expect(s.streamingText, isEmpty);
    expect(s.error, isNull);
  });

  test('AgentDoneEvent(null) → error 已达最大轮数', () {
    final s = chatSessionReducer(
        ChatSessionState.initial.copyWith(busy: true),
        AgentDoneEvent(null));
    expect(s.busy, isFalse);
    expect(s.error, '已达最大轮数');
  });

  test('ToolCallStart/End 更新轨迹', () {
    var s = chatSessionReducer(
        ChatSessionState.initial, ToolCallStartEvent('save_topic', 'c1'));
    expect(s.toolEvents, hasLength(1));
    expect(s.toolEvents.single.result, '进行中...');
    s = chatSessionReducer(
        s, ToolCallEndEvent('save_topic', '已保存', 'c1'));
    expect(s.toolEvents.single.result, '已保存');
  });

  test('AgentErrorEvent 清 pendingAsk + 置 error', () {
    final req = AskUserRequest(
      question: 'q',
      options: const [],
      multiSelect: false,
      toolCallId: 'ask-1',
    );
    var s = chatSessionReducer(
        ChatSessionState.initial.copyWith(pendingAsk: req),
        AgentErrorEvent('LLM 挂了'));
    expect(s.pendingAsk, isNull);
    expect(s.error, 'LLM 挂了');
    expect(s.busy, isFalse);
  });

  test('RetryEvent 清空 streamingText + 追加提示', () {
    var s = chatSessionReducer(
        ChatSessionState.initial.copyWith(streamingText: '半截'),
        RetryEvent(1));
    expect(s.streamingText, isEmpty);
    expect(s.toolEvents, hasLength(1));
    expect(s.toolEvents.single.result, contains('重试第 1 次'));
  });

  test('AskUserRequestedEvent 设 pendingAsk（busy 保持）', () {
    final req = AskUserRequest(
      question: '哪门学科？',
      options: const [
        AskUserOption(label: '数学', value: 'math'),
      ],
      multiSelect: false,
      toolCallId: 'ask-1',
    );
    var s = chatSessionReducer(
        ChatSessionState.initial.copyWith(busy: true),
        AskUserRequestedEvent(req));
    expect(s.pendingAsk, req);
    expect(s.busy, isTrue);
  });
}
