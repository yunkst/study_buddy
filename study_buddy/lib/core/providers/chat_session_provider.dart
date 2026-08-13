import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:study_engine/study_engine.dart';

import 'agent_session_provider.dart';
import 'screenshot_provider.dart';

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
  final AskUserRequest? pendingAsk; // 当前等待用户作答的提问，非空时输入区切语义
  final String? error;

  const ChatSessionState({
    this.messages = const [],
    this.streamingText = '',
    this.toolEvents = const [],
    this.busy = false,
    this.pendingAsk,
    this.error,
  });

  ChatSessionState copyWith({
    List<ChatMessage>? messages,
    String? streamingText,
    List<ToolEvent>? toolEvents,
    bool? busy,
    Object? pendingAsk = _sentinel,
    String? error,
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
    );
  }

  static const _sentinel = Object();

  static const initial = ChatSessionState();
}

/// 多轮会话状态管理：持有完整消息历史，每轮 send 喂给 AgentSession.run。
class ChatSessionNotifier extends StateNotifier<ChatSessionState> {
  ChatSessionNotifier(this._ref) : super(ChatSessionState.initial);
  final Ref _ref;

  StreamSubscription<AgentEvent>? _sub;
  /// 当前 send 轮的完成信号。clear()/dispose() 在流被取消（不触发 onDone）时
  /// 主动 complete，避免 send() 的 await done.future 永久挂起 + 闭包泄漏。
  Completer<void>? _done;
  /// 当前轮 agent 会话句柄，供 respondToAsk 回灌 ask_user 答案。
  AgentSessionHandle? _handle;

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
      error: null,
    );

    try {
      final session = _ref.read(agentSessionProvider);
      final handle = await session.run(msgs);
      _handle = handle;
      final stream = handle.stream;
      // 监听流：_onEvent 实时回填 state（UI 增量更新）；onDone 解除 busy。
      // send() 本身 await 整轮完成，调用方据此感知「本轮结束」。
      _done = Completer<void>();
      final done = _done!;
      _sub = stream.listen(
        _onEvent,
        onError: (Object e, StackTrace _) {
          _onError('$e');
          if (!done.isCompleted) done.complete();
        },
        onDone: () {
          _handle = null;
          if (state.busy) {
            state = state.copyWith(busy: false);
          }
          if (!done.isCompleted) done.complete();
        },
      );
      await done.future;
    } catch (e) {
      // 构造期抛错：回滚 user 消息
      _handle = null;
      state = ChatSessionState(
        messages: state.messages.sublist(0, state.messages.length - 1),
        streamingText: '',
        toolEvents: const [],
        busy: false,
        error: '$e',
      );
    } finally {
      _done = null;
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
        state = state.copyWith(toolEvents: updated);
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
        state = state.copyWith(
          messages: [...state.messages, ...newMessages],
          streamingText: '', // 本轮文本已落入 assistant 消息；清空以便下一轮独立累积
        );
      case AskUserRequestedEvent(:final request):
        // busy 保持 true（agent 仍在运行，只是挂起等用户）；UI 据此切输入区语义。
        state = state.copyWith(pendingAsk: request);
      case AskUserAnsweredEvent():
        // UI 已在 respondToAsk 里清 pendingAsk；此处仅确保状态一致。
        break;
      case AgentDoneEvent(:final finalText):
        // finalText==null 表示达到 maxRounds
        if (finalText == null) {
          state = state.copyWith(
            busy: false,
            error: '已达最大轮数',
            streamingText: '',
          );
        } else {
          // C1 修复：纯文本轮的最终回答经 AgentDoneEvent(finalText) 追加进 messages，
          // 下一轮 send 时它会成为 run 入参的一部分（多轮上下文）。
          state = state.copyWith(
            messages: [...state.messages, ChatMessage(role: 'assistant', content: finalText)],
            busy: false,
            streamingText: '',
          );
        }
      case AgentErrorEvent(:final message):
        _onError(message);
    }
  }

  void _onError(String msg) {
    if (!mounted) return;
    state = state.copyWith(busy: false, error: msg);
  }

  /// 回答当前待处理的 ask_user 提问。[answer] 是用户选中的 value 字符串（多选用", "分隔）。
  /// 由 UI 选项按钮点击或自由输入提交时调用，答案经 handle 回灌挂起的 executeTool。
  void respondToAsk(String answer) {
    if (state.pendingAsk == null) return;
    final handle = _handle;
    handle?.completeAskUser(answer);
    // 立即清空 pendingAsk，UI 据此把卡片切换到"已作答"态；真正的 ToolCallEnd
    // 在 AgentLoop 收到 completer.future 后才 yield。
    state = state.copyWith(
      pendingAsk: null,
      toolEvents: state.toolEvents.map((e) {
        if (e.name == 'ask_user' && e.result == '进行中...') {
          return ToolEvent('ask_user', '已作答: $answer');
        }
        return e;
      }).toList(),
    );
  }

  /// 重置整个会话（抽屉关闭时调用）。
  void clear() {
    _handle?.abortAskUser('会话已关闭');
    _handle = null;
    _sub?.cancel();
    _sub = null;
    // 取消订阅不触发 onDone，主动 complete 让挂起的 send() 返回，避免 future 永久悬空。
    if (_done != null && !_done!.isCompleted) {
      _done!.complete();
    }
    _done = null;
    state = ChatSessionState.initial;
  }

  @override
  void dispose() {
    _handle?.abortAskUser('会话已关闭');
    _handle = null;
    _sub?.cancel();
    if (_done != null && !_done!.isCompleted) {
      _done!.complete();
    }
    super.dispose();
  }
}

final currentChatProvider =
    StateNotifierProvider<ChatSessionNotifier, ChatSessionState>((ref) {
  return ChatSessionNotifier(ref);
});
