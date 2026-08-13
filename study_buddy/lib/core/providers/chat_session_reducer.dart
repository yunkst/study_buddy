import 'package:study_engine/study_engine.dart';

import 'chat_session_state.dart';

/// 把 AgentEvent 应用到 ChatSessionState 的纯函数（不含任何副作用）。
///
/// 事件处理逻辑的单一事实来源：ChatSessionNotifier._onEvent 用它算下一个 state，
/// 持久化等副作用在 notifier 里 case 后单独做。将来 plan_chat_sheet 若迁移到
/// ChatSessionState，也可复用本 reducer（避免同一 switch 抄第三遍）。
///
/// 事件序列契约见 agent_loop.dart：纯文本轮 = TextDelta* + AgentDoneEvent(finalText)；
/// 工具轮 = ToolCallStart/End + AgentRoundEndEvent([assistant(toolCalls), tool, ...])。
ChatSessionState chatSessionReducer(ChatSessionState state, AgentEvent event) {
  switch (event) {
    case AgentStartedEvent():
      return state;
    case TextDeltaEvent(:final delta):
      return state.copyWith(streamingText: state.streamingText + delta);
    case ToolCallStartEvent(:final name):
      return state.copyWith(
        toolEvents: [...state.toolEvents, ToolEvent(name, '进行中...')],
      );
    case ToolCallEndEvent(:final name, :final result):
      final updated = state.toolEvents.map((e) {
        if (e.name == name && e.result == '进行中...') {
          return ToolEvent(name, result);
        }
        return e;
      }).toList();
      return state.copyWith(toolEvents: updated);
    case ToolProgressEvent(:final progress):
      return state.copyWith(
        toolEvents: [...state.toolEvents, ToolEvent('·', progress)],
      );
    case CompactionEvent():
      return state.copyWith(
        toolEvents: [...state.toolEvents, const ToolEvent('·', '上下文已压缩')],
      );
    case RetryEvent(:final attempt):
      // LLM 调用失败重试：本轮已部分累积的 streamingText 会被丢弃并由 LLM
      // 重新生成，故先清空，避免新旧增量拼接出乱码；同时给可见提示。
      return state.copyWith(
        streamingText: '',
        error: null,
        toolEvents: [
          ...state.toolEvents,
          ToolEvent('·', '网络抖动，重试第 $attempt 次…'),
        ],
      );
    case AgentRoundEndEvent(:final newMessages):
      // 逐轮回填合法消息序列（assistant + tool 消息）
      return state.copyWith(
        messages: [...state.messages, ...newMessages],
        streamingText: '', // 本轮文本已落入 assistant 消息；清空以便下一轮独立累积
      );
    case AskUserRequestedEvent(:final request):
      // busy 保持 true（agent 仍在运行，只是挂起等用户）；UI 据此切输入区语义。
      return state.copyWith(pendingAsk: request);
    case AskUserAnsweredEvent():
      // UI 已在 respondToAsk 里清 pendingAsk；此处仅确保状态一致。
      return state;
    case AgentDoneEvent(:final finalText):
      // finalText==null 表示达到 maxRounds
      if (finalText == null) {
        return state.copyWith(
          busy: false,
          error: '已达最大轮数',
          streamingText: '',
        );
      }
      // 纯文本轮的最终回答经 finalText 追加进 messages，
      // 下一轮 send 时成为 run 入参的一部分（多轮上下文）。
      return state.copyWith(
        messages: [...state.messages, ChatMessage(role: 'assistant', content: finalText)],
        busy: false,
        streamingText: '',
      );
    case AgentErrorEvent(:final message):
      // 清 pendingAsk：错误后提问卡片不再有效（handle 已不可用），残留会锁死输入区。
      return state.copyWith(busy: false, error: message, pendingAsk: null);
  }
}
