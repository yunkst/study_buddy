import 'package:study_engine/study_engine.dart';

/// 工具调用轨迹条目（UI 渲染用）。
class ToolEvent {
  final String name;
  final String result; // '进行中...' 或实际结果摘要
  const ToolEvent(this.name, this.result);
}

/// 当前会话状态。messages 持有完整多轮历史。
/// [sessionId] 对应 chat_session 表（持久化/续聊用），null 表示尚未建会话。
///
/// 独立文件（而非 provider 内）：供 ChatSessionNotifier 与纯函数
/// chat_session_reducer 共同引用，避免循环 import。
class ChatSessionState {
  final List<ChatMessage> messages; // 完整多轮历史
  final String streamingText; // 当前轮 LLM 流式增量累积
  final List<ToolEvent> toolEvents; // 当前轮工具轨迹
  final bool busy; // agent 运行中
  final AskUserRequest? pendingAsk; // 当前等待用户作答的提问，非空时输入区切语义
  final String? error;
  final int? sessionId; // 当前持久化会话 id（null=新会话）

  const ChatSessionState({
    this.messages = const [],
    this.streamingText = '',
    this.toolEvents = const [],
    this.busy = false,
    this.pendingAsk,
    this.error,
    this.sessionId,
  });

  ChatSessionState copyWith({
    List<ChatMessage>? messages,
    String? streamingText,
    List<ToolEvent>? toolEvents,
    bool? busy,
    Object? pendingAsk = _sentinel,
    String? error,
    int? sessionId,
  }) {
    return ChatSessionState(
      messages: messages ?? this.messages,
      streamingText: streamingText ?? this.streamingText,
      toolEvents: toolEvents ?? this.toolEvents,
      busy: busy ?? this.busy,
      pendingAsk: identical(pendingAsk, _sentinel)
          ? this.pendingAsk
          : pendingAsk as AskUserRequest?,
      error: error,
      sessionId: sessionId ?? this.sessionId,
    );
  }

  static const _sentinel = Object();

  static const initial = ChatSessionState();
}
