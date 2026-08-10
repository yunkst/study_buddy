import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
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
      // 监听流：_onEvent 实时回填 state（UI 增量更新）；onDone 解除 busy。
      // send() 本身 await 整轮完成，调用方据此感知「本轮结束」。
      final done = Completer<void>();
      _sub = stream.listen(
        _onEvent,
        onError: (Object e, StackTrace _) {
          _onError('$e');
          if (!done.isCompleted) done.complete();
        },
        onDone: () {
          if (state.busy) {
            state = state.copyWith(busy: false);
          }
          if (!done.isCompleted) done.complete();
        },
      );
      await done.future;
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
        // 同时扫描本轮 toolCalls：若触发过 save_topic 则置 saved=true
        final roundSaved = newMessages.any(
          (m) => m.toolCalls?.any((t) => t.name == 'save_topic') ?? false,
        );
        state = state.copyWith(
          messages: [...state.messages, ...newMessages],
          saved: state.saved || roundSaved,
          streamingText: '', // 本轮文本已落入 assistant 消息；清空以便下一轮独立累积
        );
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
