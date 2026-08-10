import '../models/models.dart';

/// Agent 运行时事件流。UI 通过 Riverpod StreamProvider 订阅。
sealed class AgentEvent {}

class AgentStartedEvent extends AgentEvent {}

class TextDeltaEvent extends AgentEvent {
  final String delta;
  TextDeltaEvent(this.delta);
}

class ToolCallStartEvent extends AgentEvent {
  final String name;
  final String toolCallId;
  ToolCallStartEvent(this.name, this.toolCallId);
}

class ToolCallEndEvent extends AgentEvent {
  final String name;
  final String result;
  final String toolCallId;
  ToolCallEndEvent(this.name, this.result, this.toolCallId);
}

class ToolProgressEvent extends AgentEvent {
  final String progress;
  ToolProgressEvent(this.progress);
}

class CompactionEvent extends AgentEvent {}

class RetryEvent extends AgentEvent {
  final int attempt;
  RetryEvent(this.attempt);
}

/// 单轮 ReAct 结束：携带本轮新增的 assistant 消息及其触发的 tool 消息。
/// UI 据此 append 到会话历史，保证多轮消息序列合法。
class AgentRoundEndEvent extends AgentEvent {
  final List<ChatMessage> newMessages; // [assistant(含 toolCalls), tool, tool, ...]
  AgentRoundEndEvent(this.newMessages);
}

class AgentDoneEvent extends AgentEvent {
  final String? finalText;
  AgentDoneEvent(this.finalText);
}

class AgentErrorEvent extends AgentEvent {
  final String message;
  AgentErrorEvent(this.message);
}
