import 'dart:convert';
import '../llm/llm_provider_core.dart';
import '../logging/logger_sink.dart';
import '../models/models.dart';
import 'agent_event.dart';
import 'agent_scenario.dart';
import 'context_compactor.dart';

/// ReAct 循环：流式调 LLM → 聚合工具调用 → 执行 → 观察结果 → 进入下一轮。
/// 事件实时 yield（用纯 async*，确保流式增量立即吐出）。
class AgentLoop {
  final LlmProvider llm;
  final AgentScenario scenario;
  final ContextCompactor compactor;
  final int maxRounds;
  final LoggerSink logger;

  AgentLoop({
    required this.llm,
    required this.scenario,
    LoggerSink? logger,
    ContextCompactor? compactor,
    this.maxRounds = 50,
  })  : logger = logger ?? const NullLoggerSink(),
        compactor = compactor ?? const ContextCompactor();

  /// 运行 agent。messages 为初始消息（可选含 system）。返回实时事件流。
  /// 若调用方未传 system 消息，自动注入 scenario.buildSystemPrompt（含 context 动态信息）。
  Stream<AgentEvent> run(List<ChatMessage> messages,
      {AgentScenarioContext? context, String? traceId}) async* {
    yield AgentStartedEvent();
    logger.log(LoggerLevel.info, 'Agent 开始',
        category: 'ai', traceId: traceId, tags: const ['agent-start']);
    final msgs = [...messages];
    // 注入场景 system prompt（含 context 动态信息）。调用方已传 system 则跳过。
    if (msgs.isEmpty || msgs.first.role != 'system') {
      await scenario.getMemories(); // 填充经验记忆缓存，供 buildSystemPrompt 使用
      final sysPrompt = scenario.buildSystemPrompt(
        context ?? const AgentScenarioContext(),
      );
      msgs.insert(0, ChatMessage(role: 'system', content: sysPrompt));
    }
    var round = 0;
    try {
      while (round < maxRounds) {
        logger.log(LoggerLevel.debug, '第 $round 轮开始',
            category: 'ai', traceId: traceId, tags: const ['round']);
        final agg = <ToolCall>[];
        final buf = StringBuffer();
        await for (final chunk in llm.chatStreamWithTools(
            messages: msgs, tools: scenario.tools, traceId: traceId)) {
          if (chunk.textDelta.isNotEmpty) {
            buf.write(chunk.textDelta);
            yield TextDeltaEvent(chunk.textDelta); // 实时推送增量
          }
          if (chunk.toolCalls != null) agg.addAll(chunk.toolCalls!);
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
          try {
            result = await scenario.executeTool(tc.name, args, toolCallId: tc.id, context: context);
          } catch (e) {
            result = '工具执行出错: $e';
          }
          yield ToolCallEndEvent(tc.name, result, tc.id);
          final toolMsg = ChatMessage(role: 'tool', content: result, toolCallId: tc.id);
          msgs.add(toolMsg);
          roundNewMsgs.add(toolMsg);
        }
        yield AgentRoundEndEvent(roundNewMsgs);

        if (compactor.needsCompaction(msgs)) {
          final compacted = compactor.compact(msgs);
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
}
