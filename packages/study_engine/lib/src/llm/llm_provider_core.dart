import 'dart:convert';
import '../logging/llm_call_sink.dart';
import '../logging/logger_sink.dart';
import '../models/models.dart';
import 'llm_provider_client.dart';
import 'llm_provider_sse.dart';

class LlmStreamChunk {
  final String textDelta;
  final List<ToolCall>? toolCalls; // 仅在流结束时（末包）非空
  const LlmStreamChunk({required this.textDelta, this.toolCalls});
}

/// OpenAI 兼容流式 LLM 调用门面。
///
/// 可选注入 [llmSink]/[logger] 用于观测:成功路径由 [llmSink] 记录,
/// 异常路径同时通知 [llmSink](onError)与 [logger](error 级)。
class LlmProvider {
  final LlmConfig config;
  final LlmHttpClient _client;
  final LlmCallSink llmSink;
  final LoggerSink logger;

  LlmProvider({
    required this.config,
    LlmHttpClient? client,
    LlmCallSink? llmSink,
    LoggerSink? logger,
  })  : _client = client ?? IoLlmHttpClient(),
        llmSink = llmSink ?? const NullLlmCallSink(),
        logger = logger ?? const NullLoggerSink();

  /// 流式对话（支持工具）。每个文本片段吐一个 chunk（toolCalls 为 null），
  /// 流结束前吐一个末包：textDelta 为空、toolCalls 为聚合结果（可能为空列表表示无工具调用）。
  ///
  /// [traceId] 可选,透传给 [llmSink] 关联同一次 agent 会话的多次调用。
  Stream<LlmStreamChunk> chatStreamWithTools({
    required List<ChatMessage> messages,
    required List<Map<String, dynamic>> tools,
    String? traceId,
  }) async* {
    final uri = Uri.parse(
        '${config.apiUrl.replaceAll(RegExp(r'/+$'), '')}/chat/completions');
    final body = <String, Object?>{
      'model': config.model,
      'messages': messages.map((m) => m.toJson(forApi: true)).toList(),
      'stream': true,
      if (tools.isNotEmpty) 'tools': tools,
      if (tools.isNotEmpty) 'tool_choice': 'auto',
    };
    final headers = {'Authorization': 'Bearer ${config.apiKey}'};
    final requestBody = jsonEncode(body);

    final sw = Stopwatch()..start();
    final id = llmSink.onRequest(
      endpoint: uri.toString(),
      model: config.model,
      requestBody: requestBody,
      isStreaming: true,
      traceId: traceId,
    );

    final agg = SseToolCallAggregator();
    final fullResponse = StringBuffer();
    try {
      await for (final data in _client.postStream(uri, headers, body)) {
        fullResponse.write('$data\n');
        final chunk = jsonDecode(data) as Map<String, dynamic>;
        agg.onChunk(chunk);
        // 辅助包（usage / prompt_filter_results / error）无 choices 字段或为空，跳过。
        final choices = chunk['choices'] as List?;
        if (choices == null || choices.isEmpty) continue;
        final delta = (choices.first as Map)['delta'];
        // delta 可能为 null（仅含 finish_reason / role 标记的辅助包）——跳过，避免对 null 调 [] 崩溃。
        if (delta == null) continue;
        final content = delta['content'];
        if (content is String && content.isNotEmpty) {
          yield LlmStreamChunk(textDelta: content);
        }
      }
      sw.stop();
      // 提取 token:OpenAI 兼容流式 usage 通常在末包(若端点支持)。
      final usage = _extractUsage(fullResponse.toString());
      llmSink.onResponse(
        id,
        responseBody: fullResponse.toString(),
        durationMs: sw.elapsedMilliseconds,
        isSuccess: true,
        promptTokens: usage?.promptTokens,
        completionTokens: usage?.completionTokens,
        totalTokens: usage?.totalTokens,
      );
    } catch (e, st) {
      sw.stop();
      llmSink.onError(id,
          errorMessage: e.toString(), durationMs: sw.elapsedMilliseconds);
      logger.log(LoggerLevel.error, 'LLM 调用失败: $e',
          category: 'ai',
          traceId: traceId,
          stackTrace: st.toString(),
          tags: const ['llm']);
      rethrow;
    }
    // 末包
    yield LlmStreamChunk(textDelta: '', toolCalls: agg.result);
  }

  /// 尽力从拼接的 SSE 数据中提取 usage(prompt/completion/total tokens)。
  /// 解析失败返回 null——engine 不做协议级保证,留给 sink 实现侧兜底。
  _TokenUsage? _extractUsage(String raw) {
    try {
      final lines = raw.split('\n').where((l) => l.trim().isNotEmpty);
      int? p, c, t;
      for (final line in lines) {
        final json = jsonDecode(line) as Map<String, dynamic>;
        final usage = json['usage'] as Map<String, dynamic>?;
        if (usage != null) {
          p = usage['prompt_tokens'] as int? ?? p;
          c = usage['completion_tokens'] as int? ?? c;
          t = usage['total_tokens'] as int? ?? t;
        }
      }
      if (p == null && c == null && t == null) return null;
      return _TokenUsage(p, c, t);
    } catch (_) {
      return null;
    }
  }
}

class _TokenUsage {
  final int? promptTokens;
  final int? completionTokens;
  final int? totalTokens;
  const _TokenUsage(this.promptTokens, this.completionTokens, this.totalTokens);
}
