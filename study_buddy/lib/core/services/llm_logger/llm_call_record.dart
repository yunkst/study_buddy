// study_buddy/lib/core/services/llm_logger/llm_call_record.dart

class LlmCallRecord {
  final String id;
  final DateTime timestamp;
  final String endpoint;
  final String? model;
  final bool isStreaming;
  final String requestBody;
  final String? responseBody;
  final int? durationMs;
  final bool isSuccess;
  final String? errorMessage;
  final int? promptTokens;
  final int? completionTokens;
  final int? totalTokens;
  final String? traceId;

  const LlmCallRecord({
    required this.id,
    required this.timestamp,
    required this.endpoint,
    this.model,
    required this.isStreaming,
    required this.requestBody,
    this.responseBody,
    this.durationMs,
    required this.isSuccess,
    this.errorMessage,
    this.promptTokens,
    this.completionTokens,
    this.totalTokens,
    this.traceId,
  });

  factory LlmCallRecord.fromJson(Map<String, dynamic> j) => LlmCallRecord(
        id: j['id'] as String,
        timestamp: DateTime.fromMillisecondsSinceEpoch(j['timestamp'] as int, isUtc: true),
        endpoint: j['endpoint'] as String,
        model: j['model'] as String?,
        isStreaming: j['is_streaming'] as bool? ?? false,
        requestBody: j['request_body'] as String? ?? '',
        responseBody: j['response_body'] as String?,
        durationMs: j['duration_ms'] as int?,
        isSuccess: j['is_success'] as bool? ?? false,
        errorMessage: j['error_message'] as String?,
        promptTokens: j['prompt_tokens'] as int?,
        completionTokens: j['completion_tokens'] as int?,
        totalTokens: j['total_tokens'] as int?,
        traceId: j['trace_id'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'timestamp': timestamp.millisecondsSinceEpoch,
        'endpoint': endpoint,
        'model': model,
        'is_streaming': isStreaming,
        'request_body': requestBody,
        'response_body': responseBody,
        'duration_ms': durationMs,
        'is_success': isSuccess,
        'error_message': errorMessage,
        'prompt_tokens': promptTokens,
        'completion_tokens': completionTokens,
        'total_tokens': totalTokens,
        'trace_id': traceId,
      };

  String get previewText {
    try {
      final re = RegExp(r'"content"\s*:\s*"([^"]{0,80})');
      final matches = re.allMatches(requestBody);
      if (matches.isNotEmpty) return matches.last.group(1) ?? '';
      return requestBody.length > 80 ? requestBody.substring(0, 80) : requestBody;
    } catch (_) {
      return requestBody.length > 80 ? requestBody.substring(0, 80) : requestBody;
    }
  }

  String get durationText {
    if (durationMs == null) return '-';
    if (durationMs! < 1000) return '${durationMs}ms';
    return '${(durationMs! / 1000).toStringAsFixed(1)}s';
  }

  LlmCallRecord copyWith({
    String? responseBody, int? durationMs, bool? isSuccess, String? errorMessage,
    int? promptTokens, int? completionTokens, int? totalTokens,
  }) => LlmCallRecord(
    id: id, timestamp: timestamp, endpoint: endpoint, model: model,
    isStreaming: isStreaming, requestBody: requestBody,
    responseBody: responseBody ?? this.responseBody,
    durationMs: durationMs ?? this.durationMs,
    isSuccess: isSuccess ?? this.isSuccess,
    errorMessage: errorMessage ?? this.errorMessage,
    promptTokens: promptTokens ?? this.promptTokens,
    completionTokens: completionTokens ?? this.completionTokens,
    totalTokens: totalTokens ?? this.totalTokens,
    traceId: traceId,
  );
}
