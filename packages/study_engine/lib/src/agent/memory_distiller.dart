import '../llm/complete_text.dart';
import '../llm/llm_provider_core.dart';
import '../logging/logger_sink.dart';
import '../models/models.dart';
import '../repos/agent_memory_repository.dart';
import 'memory_policy.dart';
import 'prompts/memory_distiller_prompt.dart';

/// 记忆沉淀结果。
class MemoryDistillResult {
  final int added;
  final int skipped;
  final String? note; // 跳过/降级原因（对话过短、无候选、LLM 失败等）
  const MemoryDistillResult({this.added = 0, this.skipped = 0, this.note});
}

/// 从一次对话提炼候选记忆并写入 agent_memory（P2 自动沉淀）。
///
/// 纯 Dart 无 Flutter 依赖。写入规则与 patch_memory 一致（memory_policy 共用）：
/// 精确去重 + 容量上限；超限/重复条目跳过不中断。任何失败（LLM 异常/解析失败）均
/// 不抛出，返回空结果并记日志——调用方（UI 新对话按钮）fire-and-forget，不能影响用户体验。
class MemoryDistiller {
  final LlmProvider llm;
  final AgentMemoryRepository memories;
  final LoggerSink logger;

  MemoryDistiller({
    required this.llm,
    required this.memories,
    this.logger = const NullLoggerSink(),
  });

  /// 用户消息少于本数的对话不沉淀（省 LLM 调用）。
  static const int minUserMessages = 2;

  Future<MemoryDistillResult> distill({
    required List<ChatMessage> messages,
    required String scenarioId,
    String? traceId,
  }) async {
    final userCount = messages.where((m) => m.role == 'user').length;
    if (userCount < minUserMessages) {
      return const MemoryDistillResult(note: '对话过短，跳过沉淀');
    }

    final existing =
        (await memories.queryByScenario(scenarioId)).map((m) => m.content).toList();
    final user = '本次对话：\n${_renderConversation(messages)}\n\n'
        '现有记忆（不要重复）：\n'
        '${existing.isEmpty ? '（无）' : existing.map((e) => '- $e').join('\n')}';

    final String output;
    try {
      output = await completeText(llm,
          system: kMemoryDistillSystemPrompt, user: user, traceId: traceId);
    } catch (e, st) {
      logger.log(LoggerLevel.error, '记忆沉淀 LLM 调用失败: $e',
          category: 'ai',
          traceId: traceId,
          stackTrace: st.toString(),
          tags: const ['memory']);
      return const MemoryDistillResult(note: 'LLM 调用失败，跳过沉淀');
    }

    final candidates = _parseCandidates(output);
    if (candidates.isEmpty) {
      return const MemoryDistillResult(note: '无候选记忆');
    }

    var added = 0;
    var skipped = 0;
    for (final c in candidates) {
      if (isDuplicate(existing, c)) {
        skipped++;
        continue;
      }
      if (isOverBudget(existing, additional: [c])) {
        skipped++;
        continue;
      }
      await memories.add(scenarioId, c);
      existing.add(c);
      added++;
    }
    return MemoryDistillResult(added: added, skipped: skipped);
  }

  /// 消息列表 → 对话文本（content 兼容 String 与 vision parts）。
  String _renderConversation(List<ChatMessage> msgs) {
    final buf = StringBuffer();
    for (final m in msgs) {
      final content = switch (m.content) {
        String s => s,
        List<ContentPart> parts =>
          parts.whereType<TextPart>().map((p) => p.text).join('\n'),
        _ => '',
      };
      if (m.toolCallId != null) {
        buf.writeln('[工具结果] $content');
      } else {
        buf.writeln('[${m.role}] $content');
      }
    }
    return buf.toString();
  }

  /// 解析模型输出：逐行 `- ` 前缀提取；NOTHING → 空列表。
  List<String> _parseCandidates(String output) {
    if (output.trim().toUpperCase() == 'NOTHING') return const [];
    final list = <String>[];
    for (final line in output.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.startsWith('- ')) {
        final text = trimmed.substring(2).trim();
        if (text.isNotEmpty) list.add(text);
      }
    }
    return list;
  }
}