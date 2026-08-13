import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:study_engine/study_engine.dart';

import '../services/logger_service.dart';
import 'agent_session_provider.dart';
import 'captured_image.dart';
import 'database_provider.dart';

/// 工具调用轨迹条目（UI 渲染用）。
class ToolEvent {
  final String name;
  final String result; // '进行中...' 或实际结果摘要
  const ToolEvent(this.name, this.result);
}

/// 当前会话状态。messages 持有完整多轮历史。
/// [sessionId] 对应 chat_session 表（持久化/续聊用），null 表示尚未建会话。
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

/// 多轮会话状态管理：持有完整消息历史，每轮 send 喂给 AgentSession.run。
/// 每轮持久化到 chat_session/chat_message（App 重启后 hydrate 续聊）。
class ChatSessionNotifier extends StateNotifier<ChatSessionState> {
  ChatSessionNotifier(this._ref) : super(ChatSessionState.initial);
  final Ref _ref;

  StreamSubscription<AgentEvent>? _sub;
  /// 当前 send 轮的完成信号。clear()/dispose() 在流被取消（不触发 onDone）时
  /// 主动 complete，避免 send() 的 await done.future 永久挂起 + 闭包泄漏。
  Completer<void>? _done;
  /// 当前轮 agent 会话句柄，供 respondToAsk 回灌 ask_user 答案。
  AgentSessionHandle? _handle;
  /// 当前持久化会话 id（null=尚未建会话）。新建/续聊时填充。
  int? _sessionId;
  /// hydrate 幂等标志：冷启动只加载一次最近会话；「新对话」clear 后不重载。
  bool _hydrated = false;
  /// 首次 send 触发后台建会话的信号（用于在 session 就绪后 flush 待持久化队列）。
  Completer<void>? _sessionReady;
  /// 待持久化消息队列（先进先出，保证 user 先于 assistant/tool 落库；
  /// session 未就绪时累积，就绪后 flush）。失败时回退队列头重试。
  final List<ChatMessage> _pendingPersist = [];

  /// 冷启动恢复最近会话（续聊）。由 AiChatPage initState 调用一次；
  /// 幂等——已在内存会话（_hydrated=true）时直接跳过，避免反复覆盖用户当前对话。
  /// 无历史会话或加载失败均静默降级为全新对话（不阻断 UI）。
  Future<void> hydrate() async {
    if (_hydrated) return;
    _hydrated = true;
    try {
      final db = await _ref.read(databaseProvider.future);
      final repo = ChatRepository(db);
      final latest = await repo.latestSession('study_plan');
      final id = latest?.id;
      if (id == null) return;
      final msgs = await repo.loadMessages(id);
      if (msgs.isEmpty) return;
      _sessionId = id;
      state = ChatSessionState(messages: msgs, sessionId: id);
    } catch (e, st) {
      LoggerService.instance.w('续聊历史加载失败: $e',
          category: LogCategory.ai, stackTrace: st.toString());
    }
  }

  String _truncateTitle(String s) {
    final line = s.trim().split('\n').first;
    return line.length <= 20 ? line : '${line.substring(0, 20)}…';
  }

  /// 触发后台创建会话（仅首次）。不阻塞 send 主流程——DB 不可用/失败时
  /// 降级内存模式（_sessionId 保持 null，仅不持久化，对话不受影响）。
  void _ensureSessionAsync(String firstText) {
    if (_sessionId != null || _sessionReady != null) return;
    final ready = Completer<void>();
    _sessionReady = ready;
    _initSession(ready, firstText);
  }

  Future<void> _initSession(Completer<void> ready, String firstText) async {
    try {
      final db = await _ref.read(databaseProvider.future);
      final repo = ChatRepository(db);
      final id = await repo.createSession('study_plan', _truncateTitle(firstText));
      _sessionId = id;
      if (mounted) state = state.copyWith(sessionId: id);
    } catch (e, st) {
      LoggerService.instance.w('会话创建失败，降级内存模式: $e',
          category: LogCategory.ai, stackTrace: st.toString());
    } finally {
      if (!ready.isCompleted) ready.complete();
      // session 就绪（或降级）：flush 队列里已累积的消息。
      _flushPersist();
    }
  }

  /// 消息进入待持久化队列（可剥离图片）。session 已就绪则立即 flush。
  void _enqueuePersist(Iterable<ChatMessage> msgs, {bool stripImage = false}) {
    _pendingPersist.addAll(stripImage ? msgs.map(_stripImage) : msgs);
    if (_sessionId != null) _flushPersist();
  }

  /// 把队列按序批量写库 + touch 会话时间戳。失败回退队列头（不丢消息）。
  void _flushPersist() {
    final sid = _sessionId;
    if (sid == null || _pendingPersist.isEmpty) return;
    final batch = List<ChatMessage>.from(_pendingPersist);
    _pendingPersist.clear();
    _ref.read(databaseProvider.future).then((db) async {
      final repo = ChatRepository(db);
      await repo.appendMessages(sid, batch);
      await repo.touchSession(sid);
    }).catchError((Object e, StackTrace st) {
      // 写失败：回退队列头，下次 flush 重试；不阻断对话。
      _pendingPersist.insertAll(0, batch);
      LoggerService.instance.w('消息持久化失败: $e',
          category: LogCategory.ai, stackTrace: st.toString());
    });
  }

  /// 剥离 user 消息的图片 part（base64 体积大，不落库），只保留文本。
  /// 纯文本或已是文本的消息原样返回。
  ChatMessage _stripImage(ChatMessage m) {
    final c = m.content;
    if (c is String) return m;
    final parts = c as List<ContentPart>;
    if (parts.every((p) => p is TextPart)) return m;
    final text = parts.whereType<TextPart>().map((p) => p.text).join('\n');
    return ChatMessage(
      role: m.role,
      content: text,
      toolCalls: m.toolCalls,
      toolCallId: m.toolCallId,
    );
  }

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
      // 后台建会话（不阻塞）；user 消息进队列，session 就绪后按序落库。
      _ensureSessionAsync(trimmed);
      final session = _ref.read(agentSessionProvider);
      final handle = await session.run(msgs, chatSessionId: _sessionId);
      _handle = handle;
      // 存 user 消息（剥离图片）。chat_session_id 已注入 ctx，
      // save_review 的批改记录也能关联到本会话。
      _enqueuePersist([userMsg], stripImage: true);
      final stream = handle.stream;
      // 监听流：_onEvent 实时回填 state（UI 增量更新）；onDone 解除 busy。
      // send() 本身 await 整轮完成，调用方据此感知「本轮结束」。
      _done = Completer<void>();
      final done = _done!;
      _sub = stream.listen(
        _onEvent,
        onError: (Object e, StackTrace _) {
          _onError('$e');
          _handle = null;
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
        // LLM 调用失败重试：本轮已部分累积的 streamingText 会被丢弃并由 LLM 重新生成，
        // 故先清空，避免新旧增量拼接出乱码；同时给用户一个「正在重连」的可见提示。
        state = state.copyWith(
          streamingText: '',
          error: null,
          toolEvents: [...state.toolEvents, ToolEvent('·', '网络抖动，重试第 $attempt 次…')],
        );
      case AgentRoundEndEvent(:final newMessages):
        // 逐轮回填合法消息序列（assistant + tool 消息）
        state = state.copyWith(
          messages: [...state.messages, ...newMessages],
          streamingText: '', // 本轮文本已落入 assistant 消息；清空以便下一轮独立累积
        );
        // 持久化本轮 assistant+tool（content 均为纯文本，无需剥图）
        _enqueuePersist(newMessages);
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
          final doneMsg = ChatMessage(role: 'assistant', content: finalText);
          state = state.copyWith(
            messages: [...state.messages, doneMsg],
            busy: false,
            streamingText: '',
          );
          _enqueuePersist([doneMsg]); // 持久化纯文本轮回答
        }
      case AgentErrorEvent(:final message):
        _onError(message);
    }
  }

  void _onError(String msg) {
    if (!mounted) return;
    // 清 pendingAsk：错误后提问卡片不再有效（handle 已不可用），残留会让输入区锁死。
    state = state.copyWith(busy: false, error: msg, pendingAsk: null);
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

  /// 重置整个会话（新对话按钮 / App 退出时调用）。
  /// 注意：不清 _hydrated——「新对话」后不该重载旧会话；App 进程被杀后
  /// provider 重建会重新 hydrate（续聊依赖此语义）。
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
    _sessionId = null;
    _sessionReady = null;
    _pendingPersist.clear();
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
