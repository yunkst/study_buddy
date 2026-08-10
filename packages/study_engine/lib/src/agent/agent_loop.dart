import 'dart:convert';
import '../llm/llm_provider_core.dart';
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

  AgentLoop({
    required this.llm,
    required this.scenario,
    ContextCompactor? compactor,
    this.maxRounds = 50,
  }) : compactor = compactor ?? const ContextCompactor();

  /// 运行 agent。messages 为初始消息（可选含 system）。返回实时事件流。
  /// 若调用方未传 system 消息，自动注入 scenario.buildSystemPrompt（含 context 动态信息）。
  Stream<AgentEvent> run(List<ChatMessage> messages, {AgentScenarioContext? context}) async* {
    yield AgentStartedEvent();
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
        final agg = <ToolCall>[];
        final buf = StringBuffer();
        await for (final chunk in llm.chatStreamWithTools(messages: msgs, tools: scenario.tools)) {
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
          yield AgentDoneEvent(buf.toString());
          return;
        }

        // assistant 消息携带 tool_calls
        msgs.add(ChatMessage(role: 'assistant', content: buf.toString(), toolCalls: agg));
        for (final tc in agg) {
          yield ToolCallStartEvent(tc.name, tc.id);
          final args = _parseArgs(tc.arguments);
          String result;
          try {
            result = await scenario.executeTool(tc.name, args, toolCallId: tc.id);
          } catch (e) {
            result = '工具执行出错: $e';
          }
          yield ToolCallEndEvent(tc.name, result, tc.id);
          msgs.add(ChatMessage(role: 'tool', content: result, toolCallId: tc.id));
        }

        if (compactor.needsCompaction(msgs)) {
          final compacted = compactor.compact(msgs);
          msgs
            ..clear()
            ..addAll(compacted);
          yield CompactionEvent();
        }
        round++;
        if (round >= maxRounds) {
          yield AgentDoneEvent(null);
          return;
        }
      }
    } catch (e) {
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
