import 'dart:async';
import 'dart:convert';
import 'dart:math';

import '../llm/llm_provider_core.dart';
import '../logging/logger_sink.dart';
import '../models/models.dart';
import 'agent_event.dart';
import 'agent_scenario.dart';
import 'ask_user.dart';
import 'context_compactor.dart';
import 'tool_output_truncator.dart';

/// LLM 远程调用失败的重试策略。
///
/// 作用于 **单次 LLM 流式调用**（即一轮 ReAct 内的一次 chatStreamWithTools），
/// 而不是整个 agent 会话。策略对 **所有** 异常一视同仁——无论是网络中断、
/// 超时、HTTP 4xx/5xx 还是协议解析错误——都按 [maxAttempts] 重试，尽最大努力
/// 吞掉远程服务的临时抖动，避免单次失败直接中断整个对话。
///
/// 流式语义下的一个不可避免约束：若 LLM 已经开始返回文本（增量已下发）后连接中断，
/// 重试会触发一次完整重发——因为 SSE 不支持断点续传。此时本轮已累积的流式文本会被
/// 重置（通过 [RetryEvent] 通知 UI 清空 streamingText），由 LLM 重新生成，
/// 杜绝半截拼接。这比"直接报错中断对话"更符合「不中断」的目标。
class RetryConfig {
  /// 总尝试次数（含首次）。为 1 表示不重试。
  final int maxAttempts;

  /// 首次重试前的固定退避基数（毫秒），后续按 2^n 指数增长。
  final int baseDelayMs;

  /// 每次退避的随机抖动上限（毫秒），避免多客户端同时重试打爆服务。
  final int jitterMs;

  const RetryConfig({this.maxAttempts = 3, this.baseDelayMs = 500, this.jitterMs = 250});

  /// 完全不重试（保留给测试或显式关闭重试的场景）。
  static const RetryConfig none = RetryConfig(maxAttempts: 1, baseDelayMs: 0, jitterMs: 0);
}

/// ReAct 循环：流式调 LLM → 聚合工具调用 → 执行 → 观察结果 → 进入下一轮。
/// 事件实时 yield（用纯 async*，确保流式增量立即吐出）。
class AgentLoop {
  /// abortAskUser 完成 completer 的哨兵值，标识“用户取消/会话中断”而非真实作答。
  /// abortAskUser 完成 completer 的哨兵对象，标识“用户取消/会话中断”而非真实作答。
  ///
  /// 用唯一 `Object()` 实例而非字符串：`run` 用 `identical` 判等，真实用户答案
  /// （[completeAskUser] 的 String）是不同类型/实例，永不会被误判为取消——无隐含
  /// “答案不得等于某字符串”的约束。completer 类型因此升为 `Completer<Object?>`。
  static final _askAbortedMarker = Object();
  final LlmProvider llm;
  final AgentScenario scenario;
  final ContextCompactor compactor;
  final int maxRounds;
  final LoggerSink logger;
  final RetryConfig retry;
  final Random _random;
  final String? toolTmpDir; // 非空时超长工具输出落此目录；null=不截断（测试默认）

  // ---- ask_user 挂起句柄 ----
  // AgentLoop 每次 run() 由 session 重新构造，completer 挂在这里避免跨轮串话。
  // UI 通过 session 返回的 handle 调 [completeAskUser]/[abortAskUser] 喂答案/中止。

  /// 当前 ask_user 等待用户作答的句柄。拦截 ask_user 时创建，答完/中止后清空。
  ///
  /// 类型为 `Object?`：正常作答完成一个 String（用户答案），中止完成
  /// [_askAbortedMarker]（唯一 Object 实例）。[run] 用 `identical` 区分。
  Completer<Object?>? askUserCompleter;

  /// 当前正在等待用户作答的请求（供 UI 显示）。触发时设置，作答/中止后置空。
  AskUserRequest? pendingAskRequest;

  AgentLoop({
    required this.llm,
    required this.scenario,
    LoggerSink? logger,
    ContextCompactor? compactor,
    this.maxRounds = 50,
    RetryConfig? retry,
    Random? random,
    this.toolTmpDir,
  })  : logger = logger ?? const NullLoggerSink(),
        compactor = compactor ?? const ContextCompactor(),
        retry = retry ?? const RetryConfig(),
        _random = random ?? Random();

  /// UI 调用：把用户答案喂给挂起的 ask_user 工具调用。
  /// [answer] 是用户选中的 value 字符串（多选用", "分隔）。
  void completeAskUser(String answer) {
    final c = askUserCompleter;
    if (c != null && !c.isCompleted) {
      c.complete(answer);
    }
    pendingAskRequest = null;
  }

  /// 取消挂起的等待（流被取消/出错时调用，避免 completer 泄漏）。
  /// 用 sentinel 对象而非 completeError：在 async* 生成器 yield 期间同步调用
  /// completeError 会让错误逃逸成未处理的流错误，绕开内部 catch。
  /// sentinel 是唯一 Object 实例，[run] 用 `identical` 判别。
  void abortAskUser(Object error) {
    final c = askUserCompleter;
    if (c != null && !c.isCompleted) {
      c.complete(_askAbortedMarker);
    }
    pendingAskRequest = null;
  }

  /// 运行 agent。messages 为初始消息（可选含 system）。返回实时事件流。
  /// 若调用方未传 system 消息，自动注入 scenario.buildSystemPrompt（含 context 动态信息）。
  Stream<AgentEvent> run(List<ChatMessage> messages,
      {AgentScenarioContext? context, String? traceId}) async* {
    yield AgentStartedEvent();
    // 防御性重置上一轮的 ask_user 状态（正常路径已在答完/中止后清空）。
    askUserCompleter = null;
    pendingAskRequest = null;
    logger.log(LoggerLevel.info, 'Agent 开始',
        category: 'ai', traceId: traceId, tags: const ['agent-start']);
    final msgs = [...messages];
    // 先填充经验记忆缓存（无论调用方是否已传 system 都调）：
    // 阶段 1 起记忆不再进 system prompt，而是经 composeApiMessages 注入
    // 当前轮用户消息——因此 getMemories 必须在每次 run 早期执行。
    await scenario.getMemories();
    // 注入场景 system prompt（含 context 动态信息）。调用方已传 system 则跳过。
    if (msgs.isEmpty || msgs.first.role != 'system') {
      final sysPrompt = scenario.buildSystemPrompt(
        context ?? const AgentScenarioContext(),
      );
      msgs.insert(0, ChatMessage(role: 'system', content: sysPrompt));
    }
    // 交给场景构造「发给 LLM 的消息」（记忆等注入到当前用户消息的 apiContent）。
    // 返回新列表；默认实现原样返回。
    final composed = scenario.composeApiMessages(msgs, context ?? const AgentScenarioContext());
    final finalMsgs = List<ChatMessage>.unmodifiable(composed);
    msgs
      ..clear()
      ..addAll(finalMsgs);
    var round = 0;
    try {
      while (round < maxRounds) {
        logger.log(LoggerLevel.debug, '第 $round 轮开始',
            category: 'ai', traceId: traceId, tags: const ['round']);
        final agg = <ToolCall>[];
        var buf = StringBuffer();
        // —— LLM 流式调用 + 失败重试 ——
        // 所有异常都重试到 retry.maxAttempts；重试前丢弃本轮已累积的文本/工具调用，
        // 并 yield RetryEvent 通知 UI 重置 streamingText（LLM 将重新生成本轮）。
        var attempts = 0;
        while (true) {
          var failed = false;
          try {
            await for (final chunk in llm.chatStreamWithTools(
                messages: msgs, tools: scenario.tools, traceId: traceId)) {
              if (chunk.textDelta.isNotEmpty) {
                buf.write(chunk.textDelta);
                yield TextDeltaEvent(chunk.textDelta); // 实时推送增量
              }
              if (chunk.toolCalls != null) agg.addAll(chunk.toolCalls!);
            }
          } catch (e, st) {
            attempts++;
            logger.log(LoggerLevel.warning, 'LLM 调用失败(第 $attempts 次): $e',
                category: 'ai',
                traceId: traceId,
                stackTrace: st.toString(),
                tags: const ['llm-retry']);
            if (attempts >= retry.maxAttempts) rethrow; // 耗尽：交外层 catch 收尾
            failed = true;
          }
          if (!failed) break; // 本轮 LLM 调用成功，跳出重试循环
          // 准备重试：清空本轮已部分累积的缓冲，避免新旧增量拼接出乱码
          agg.clear();
          buf = StringBuffer();
          yield RetryEvent(attempts);
          await Future<void>.delayed(_backoffMs(attempts));
        }

        if (agg.isEmpty) {
          final inject = await scenario.onNoToolCalls(msgs);
          if (inject != null) {
            msgs.add(ChatMessage(role: 'user', content: inject));
            round++;
            continue;
          }
          logger.log(LoggerLevel.info, 'Agent 完成',
              category: 'ai', traceId: traceId, tags: const ['agent-done']);
          yield AgentDoneEvent(buf.toString());
          return;
        }

        // assistant 消息携带 tool_calls
        final assistantMsg = ChatMessage(role: 'assistant', content: buf.toString(), toolCalls: agg);
        msgs.add(assistantMsg);
        final roundNewMsgs = <ChatMessage>[assistantMsg];
        for (final tc in agg) {
          logger.log(LoggerLevel.info, '工具调用: ${tc.name}',
              category: 'ai', traceId: traceId, tags: const ['tool-call']);
          yield ToolCallStartEvent(tc.name, tc.id);
          final args = _parseArgs(tc.arguments);
          String result;

          // ask_user 特殊路径：拦下并挂起，等 UI 用户作答后把答案作为工具结果。
          if (tc.name == 'ask_user') {
            final request = _buildAskUserRequest(tc, args);
            final completer = Completer<Object?>();
            askUserCompleter = completer;
            pendingAskRequest = request;
            yield AskUserRequestedEvent(request);

            final answer = await completer.future;
            askUserCompleter = null;
            pendingAskRequest = null;
            if (identical(answer, _askAbortedMarker)) {
              // 用户取消 / 会话中断：当作错误结果回填给 LLM。
              result = '用户取消或会话中断';
              yield ToolCallEndEvent(tc.name, result, tc.id);
              final toolMsg = ChatMessage(role: 'tool', content: result, toolCallId: tc.id);
              msgs.add(toolMsg);
              roundNewMsgs.add(toolMsg);
              continue;
            }
            result = answer as String;
            yield AskUserAnsweredEvent(tc.id, result);
          } else {
            try {
              final raw = await scenario.executeTool(tc.name, args, toolCallId: tc.id, context: context);
              // 超长工具输出落临时文件（opencode 风格），给 LLM 保留可追溯指针；
              // toolTmpDir 为 null（测试默认）时不截断。
              result = truncateToolOutput(raw, tmpDir: toolTmpDir);
            } catch (e) {
              result = '工具执行出错: $e';
            }
          }

          yield ToolCallEndEvent(tc.name, result, tc.id);
          final toolMsg = ChatMessage(role: 'tool', content: result, toolCallId: tc.id);
          msgs.add(toolMsg);
          roundNewMsgs.add(toolMsg);
        }
        yield AgentRoundEndEvent(roundNewMsgs);

        if (compactor.needsCompaction(msgs)) {
          final compacted = await compactor.compactAsync(msgs);
          msgs
            ..clear()
            ..addAll(compacted);
          yield CompactionEvent();
        }
        round++;
        if (round >= maxRounds) {
          logger.log(LoggerLevel.warning, 'Agent 达到最大轮次 $maxRounds',
              category: 'ai', traceId: traceId, tags: const ['max-rounds']);
          yield AgentDoneEvent(null);
          return;
        }
      }
    } catch (e, st) {
      logger.log(LoggerLevel.error, 'Agent 异常: $e',
          category: 'ai',
          traceId: traceId,
          stackTrace: st.toString(),
          tags: const ['agent-error']);
      yield AgentErrorEvent(e.toString());
    } finally {
      // 流任何路径终止都确保 ask_user 句柄不泄漏（例如用户关闭抽屉、LLM 网络异常）。
      if (askUserCompleter != null && !askUserCompleter!.isCompleted) {
        abortAskUser('Agent 流中断');
      }
    }
  }

  Map<String, dynamic> _parseArgs(String raw) {
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : {};
    } catch (_) {
      return {};
    }
  }

  /// 指数退避 + 抖动：baseDelay * 2^(attempt-1)，再叠加 [0, jitter)。
  /// attempt 从 1 起（首次重试的等待）。
  Duration _backoffMs(int attempt) {
    final exp = attempt - 1 < 0 ? 0 : attempt - 1;
    // 防止 1 << exp 在极端配置下溢出，封顶 30 位（~1e9 ms）。
    final shift = exp > 30 ? 30 : exp;
    // 先把 base clamp 到 24h，再加 jitter：避免 base + jitter 直接相加溢出 int64。
    // 24h 远超任何合理重试间隔。
    const maxMs = 24 * 60 * 60 * 1000;
    final base = retry.baseDelayMs * (1 << shift);
    final cappedBase = base > maxMs ? maxMs : base;
    final jitter = retry.jitterMs <= 0 ? 0 : _random.nextInt(retry.jitterMs);
    final ms = cappedBase + jitter > maxMs ? maxMs : cappedBase + jitter;
    return Duration(milliseconds: ms);
  }

  /// 把 ask_user 工具参数解析为 [AskUserRequest]（无 yield，纯构造）。
  AskUserRequest _buildAskUserRequest(ToolCall tc, Map<String, dynamic> args) {
    final options = ((args['options'] as List?) ?? const [])
        .map((e) {
          final m = Map<String, dynamic>.from(e as Map);
          return AskUserOption(
            label: m['label'] as String,
            value: m['value'] as String,
            description: m['description'] as String?,
          );
        })
        .toList();
    return AskUserRequest(
      question: (args['question'] as String?) ?? '',
      header: args['header'] as String?,
      options: options,
      multiSelect: (args['multi_select'] as bool?) ?? false,
      toolCallId: tc.id,
    );
  }
}

/// 一次 agent 会话的句柄：持有事件流，并向 UI 暴露 ask_user 的喂答案/中止能力。
/// 由 session provider 的 run() 返回；UI 监听 [stream] 的同时，可在
/// [AskUserRequestedEvent] 到达后调用 [completeAskUser] 把用户答案回灌。
///
/// 用回调而非直接持有 AgentLoop：生产代码由 session 把回调接到 loop 上，
/// 测试/假实现可零成本构造（不需要真实 AgentLoop/LlmProvider）。
class AgentSessionHandle {
  /// agent 事件流（实时增量）。
  final Stream<AgentEvent> stream;

  final void Function(String)? _completeAskUser;
  final void Function(Object)? _abortAskUser;

  AgentSessionHandle({
    required this.stream,
    void Function(String)? completeAskUser,
    void Function(Object)? abortAskUser,
  })  : _completeAskUser = completeAskUser,
        _abortAskUser = abortAskUser;

  /// 把用户答案喂给挂起的 ask_user 工具调用。answer 为 value 字符串（多选用", "分隔）。
  void completeAskUser(String answer) => _completeAskUser?.call(answer);

  /// 中止挂起的 ask_user 等待（用户取消/关闭面板时调用）。
  void abortAskUser(Object error) => _abortAskUser?.call(error);
}