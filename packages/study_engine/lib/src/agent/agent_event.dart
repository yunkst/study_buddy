import '../models/models.dart';
import 'ask_user.dart';

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

/// ask_user 工具触发：UI 渲染提问卡片，等待用户作答。
/// 在 ToolCallStartEvent 之后、ToolCallEndEvent 之前 yield。
class AskUserRequestedEvent extends AgentEvent {
  final AskUserRequest request;
  AskUserRequestedEvent(this.request);
}

/// 用户提交答案后 yield（在 AskUserRequestedEvent 之后、ToolCallEndEvent 之前）。
/// UI 据此把卡片从“等待中”切换到“已作答”，避免重复提交。
class AskUserAnsweredEvent extends AgentEvent {
  final String toolCallId;
  final String answer; // 用户最终选/输入的 value（多选用", "分隔）
  AskUserAnsweredEvent(this.toolCallId, this.answer);
}
