import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:study_engine/study_engine.dart';

import '../services/logger_service.dart';
import 'agent_session_provider.dart';
import 'captured_image.dart';
import 'chat_session_reducer.dart';
import 'chat_session_state.dart';
import 'database_provider.dart';

export 'chat_session_state.dart'; // ChatSessionState/ToolEvent 原定义处 re-export

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
  /// 教学 topic（详情页【为什么？】入口），`startTeaching` 设置、`clear` 重置。
  /// null=普通学习伴侣会话。send 时透传给 agent。
  int? _topicId;
  /// 当前 startTeaching 的首个文字 token 信号：首个 TextDeltaEvent 到达即 complete，
  /// 纯工具轮/整轮结束/错误作为兜底放行（避免 startTeaching 永挂）。
  Completer<void>? _firstToken;
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
      final id = await repo.createSession('study_plan', _truncateTitle(firstText), topicId: _topicId);
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
      final handle = await session.run(
        msgs,
        chatSessionId: _sessionId,
        topicId: _topicId,
      );
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
          if (_firstToken != null && !_firstToken!.isCompleted) {
            _firstToken!.completeError('$e');
          }
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
      // 构造期抛错：回滚 user 消息。agent_loop 尚未启动，异常仅此可观测，须记录。
      if (_firstToken != null && !_firstToken!.isCompleted) {
        _firstToken!.completeError('$e');
      }
      LoggerService.instance.e('AI 会话启动失败: $e',
          category: LogCategory.ai, tags: const ['chat-session-start']);
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
    // startTeaching 的首个文字 token 放行；纯工具轮/整轮结束/错误作为兜底放行，
    // 避免 startTeaching 永挂。
    if (_firstToken != null && !_firstToken!.isCompleted) {
      if (event is TextDeltaEvent || event is AgentDoneEvent) {
        _firstToken!.complete();
      } else if (event is AgentErrorEvent) {
        _firstToken!.completeError(event.message);
      }
    }
    // 状态变更交给纯函数（事件处理单一事实来源）；副作用（持久化）在此单独做。
    state = chatSessionReducer(state, event);
    if (event is AgentRoundEndEvent) {
      // 持久化本轮 assistant+tool（content 均为纯文本，无需剥图）
      _enqueuePersist(event.newMessages);
    } else if (event is AgentDoneEvent && event.finalText != null) {
      // 持久化纯文本轮回答（与 reducer 追加的 assistant 消息一致）
      _enqueuePersist(
          [ChatMessage(role: 'assistant', content: event.finalText!)]);
    }
  }

  void _onError(String msg) {
    if (!mounted) return;
    // 流 onError 回调（非事件）：与 AgentErrorEvent 同样清 pendingAsk + 报错。
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
    _topicId = null;
    if (_firstToken != null && !_firstToken!.isCompleted) {
      _firstToken!.completeError(StateError('会话已重置'));
    }
    _firstToken = null;
    _pendingPersist.clear();
    state = ChatSessionState.initial;
  }

  /// 启动「知识点教学模式」（详情页【为什么？】入口）。
  ///
  /// 返回的 Future 在「可展示」时 resolve：已有历史教学会话则直接恢复（零 LLM 调用）；
  /// 无历史则新建教学会话 + 发开场消息，等首个文字 token（TextDeltaEvent）到达即 resolve
  /// （不等整轮结束）。失败时抛出（构造期抛错 / AgentErrorEvent / 会话被 clear 重置）。
  Future<void> startTeaching(int topicId) async {
    clear();
    _topicId = topicId;
    // 1) 先尝试恢复该 topic 的历史教学会话（有则直接展示，不请求 LLM）
    if (await _tryRestoreTeaching(topicId)) return;
    // 2) 无历史：新建教学会话 + 发开场消息，等首个文字 token
    final firstToken = Completer<void>();
    _firstToken = firstToken;
    // unawaited 后由 _onEvent 完成 _firstToken；.catchError 兜底防未处理异常
    // （_firstToken 的 completeError 由 _onEvent 的 AgentErrorEvent / send 构造期 catch 完成）。
    unawaited(send(_teachingOpeningPrompt).catchError((Object _) {}));
    await firstToken.future;
  }

  /// 尝试恢复该知识点已持久化的教学会话。命中且有消息 → 载入 state 返回 true。
  /// 无会话 / 无消息 / 读库失败 → 返回 false（调用方走开场路径）。
  Future<bool> _tryRestoreTeaching(int topicId) async {
    try {
      final db = await _ref.read(databaseProvider.future);
      final repo = ChatRepository(db);
      final session = await repo.findTeachingSession(topicId);
      if (session == null) return false;
      final id = session.id;
      if (id == null) return false;
      final msgs = await repo.loadMessages(id);
      if (msgs.isEmpty) return false;
      _sessionId = session.id;
      state = ChatSessionState(messages: msgs, sessionId: session.id);
      return true;
    } catch (e, st) {
      LoggerService.instance.w('教学会话恢复失败: $e',
          category: LogCategory.ai, stackTrace: st.toString());
      return false;
    }
  }

  /// 教学开场指令（详情页【为什么？】入口）：作为首条 user 消息触发 AI 自动开场。
  /// 知识点内容由 system prompt（topic_context 占位符）注入，故模板不依赖具体知识点。
  static const String _teachingOpeningPrompt =
      '我要理解这个知识点。请先给我讲一个它诞生的具体场景——它当初是为了解决什么问题而诞生的，'
      '或它现在被用在什么实际情境里。然后从这个场景出发，向我介绍这个知识点解决了什么、'
      '核心思想是什么。讲完场景和动机后，再一步步引导我理解，一次只讲一步，'
      '多用提问确认我懂了没有。';

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

/// 知识点教学会话（详情页【为什么？】入口）：独立于主线的专属会话，
/// 与 currentChatProvider 完全隔离，互不覆盖。topicId 由 startTeaching 动态设置。
final topicTeachingProvider =
    StateNotifierProvider<ChatSessionNotifier, ChatSessionState>((ref) {
  return ChatSessionNotifier(ref);
});
