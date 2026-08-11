// packages/study_engine/lib/src/logging/llm_call_sink.dart

/// LLM 调用观测出口。
///
/// 调用流程:[onRequest] 返回 id → engine 存住 id →
/// [onResponse](id) 或 [onError](id)。id 关联由 sink 实现负责。
abstract class LlmCallSink {
  /// 记录请求开始,返回记录 id(engine 透传给 onResponse/onError)。
  String onRequest({
    required String endpoint,
    required String model,
    required String requestBody,
    required bool isStreaming,
    String? traceId,
  });

  /// 记录响应完成(含 token 统计与耗时)。
  void onResponse(
    String id, {
    required String responseBody,
    required int durationMs,
    required bool isSuccess,
    String? errorMessage,
    int? promptTokens,
    int? completionTokens,
    int? totalTokens,
  });

  /// 记录请求失败。
  void onError(
    String id, {
    required String errorMessage,
    int? durationMs,
  });
}

/// noop 实现:engine 测试与未注入时使用。const 构造,onRequest 返回空串。
class NullLlmCallSink implements LlmCallSink {
  const NullLlmCallSink();

  @override
  String onRequest({
    required String endpoint,
    required String model,
    required String requestBody,
    required bool isStreaming,
    String? traceId,
  }) =>
      '';

  @override
  void onResponse(
    String id, {
    required String responseBody,
    required int durationMs,
    required bool isSuccess,
    String? errorMessage,
    int? promptTokens,
    int? completionTokens,
    int? totalTokens,
  }) {}

  @override
  void onError(String id, {required String errorMessage, int? durationMs}) {}
}
