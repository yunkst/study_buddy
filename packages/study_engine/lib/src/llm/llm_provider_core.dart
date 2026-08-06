import 'dart:convert';
import '../models/models.dart';
import 'llm_provider_client.dart';
import 'llm_provider_sse.dart';

class LlmStreamChunk {
  final String textDelta;
  final List<ToolCall>? toolCalls; // 仅在流结束时（末包）非空
  const LlmStreamChunk({required this.textDelta, this.toolCalls});
}

/// OpenAI 兼容流式 LLM 调用门面。
class LlmProvider {
  final LlmConfig config;
  final LlmHttpClient _client;
  LlmProvider({required this.config, LlmHttpClient? client})
      : _client = client ?? IoLlmHttpClient();

  /// 流式对话（支持工具）。每个文本片段吐一个 chunk（toolCalls 为 null），
  /// 流结束前吐一个末包：textDelta 为空、toolCalls 为聚合结果（可能为空列表表示无工具调用）。
  Stream<LlmStreamChunk> chatStreamWithTools({
    required List<ChatMessage> messages,
    required List<Map<String, dynamic>> tools,
  }) async* {
    final uri = Uri.parse('${config.apiUrl.replaceAll(RegExp(r'/+$'), '')}/chat/completions');
    final body = <String, Object?>{
      'model': config.model,
      'messages': messages.map((m) => m.toJson()).toList(),
      'stream': true,
      if (tools.isNotEmpty) 'tools': tools,
      if (tools.isNotEmpty) 'tool_choice': 'auto',
    };
    final headers = {'Authorization': 'Bearer ${config.apiKey}'};
    final agg = SseToolCallAggregator();
    await for (final data in _client.postStream(uri, headers, body)) {
      final chunk = jsonDecode(data) as Map<String, dynamic>;
      agg.onChunk(chunk);
      final delta = ((chunk['choices'] as List).first as Map)['delta'];
      final content = delta['content'];
      if (content is String && content.isNotEmpty) {
        yield LlmStreamChunk(textDelta: content);
      }
    }
    // 末包
    yield LlmStreamChunk(textDelta: '', toolCalls: agg.result);
  }
}
