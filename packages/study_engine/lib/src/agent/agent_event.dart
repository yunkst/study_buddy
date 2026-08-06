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

class AgentDoneEvent extends AgentEvent {
  final String? finalText;
  AgentDoneEvent(this.finalText);
}

class AgentErrorEvent extends AgentEvent {
  final String message;
  AgentErrorEvent(this.message);
}
