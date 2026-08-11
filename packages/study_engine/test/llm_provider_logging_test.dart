import 'package:test/test.dart';
import 'package:study_engine/study_engine.dart';

/// 记录所有调用的 fake LlmCallSink。
class _RecordingSink implements LlmCallSink {
  String? lastRequestEndpoint;
  String? lastRequestModel;
  String? lastRequestBody;
  bool? lastRequestStreaming;
  String? lastTraceId;
  String? responseId;
  String? responseBody;
  int? responseDurationMs;
  bool? responseSuccess;
  String? errorMessage;

  @override
  String onRequest({
    required String endpoint,
    required String model,
    required String requestBody,
    required bool isStreaming,
    String? traceId,
  }) {
    lastRequestEndpoint = endpoint;
    lastRequestModel = model;
    lastRequestBody = requestBody;
    lastRequestStreaming = isStreaming;
    lastTraceId = traceId;
    return 'rec-1';
  }

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
  }) {
    responseId = id;
    this.responseBody = responseBody;
    responseDurationMs = durationMs;
    responseSuccess = isSuccess;
    this.errorMessage = errorMessage;
  }

  @override
  void onError(String id, {required String errorMessage, int? durationMs}) {}
}

class _FakeClient implements LlmHttpClient {
  _FakeClient(this.lines);
  final List<String> lines;
  @override
  Stream<String> postStream(
          Uri uri, Map<String, String> headers, Map<String, Object?> body) =>
      Stream.fromIterable(lines);
}

void main() {
  test('LlmProvider 成功时 onRequest→onResponse 顺序调用并带 traceId', () async {
    final sink = _RecordingSink();
    final cfg = LlmConfig(
        name: 't',
        apiUrl: 'https://api.example.com/v1',
        apiKey: 'k',
        model: 'gpt-x',
        createdAt: DateTime.now());
    final lines = [
      '{"choices":[{"delta":{"content":"hi"}}]}',
      '{"choices":[{"delta":{}}]}',
    ];
    final provider =
        LlmProvider(config: cfg, client: _FakeClient(lines), llmSink: sink);
    await provider
        .chatStreamWithTools(messages: [], tools: [], traceId: 'trace-99')
        .toList();

    expect(sink.lastRequestEndpoint, 'https://api.example.com/v1/chat/completions');
    expect(sink.lastRequestModel, 'gpt-x');
    expect(sink.lastRequestStreaming, isTrue);
    expect(sink.lastTraceId, 'trace-99');
    expect(sink.lastRequestBody, contains('gpt-x'));
    expect(sink.responseId, 'rec-1');
    expect(sink.responseSuccess, isTrue);
    expect(sink.responseDurationMs, greaterThanOrEqualTo(0));
    // 响应体拼接了两个 data 行
    expect(sink.responseBody, contains('hi'));
  });

  test('LlmProvider 默认 NullLlmCallSink 不抛异常', () async {
    final cfg = LlmConfig(
        name: 't',
        apiUrl: 'https://api.example.com/v1',
        apiKey: 'k',
        model: 'm',
        createdAt: DateTime.now());
    final provider = LlmProvider(
        config: cfg, client: _FakeClient(['{"choices":[{"delta":{"content":"x"}}]}']));
    final chunks =
        await provider.chatStreamWithTools(messages: [], tools: []).toList();
    expect(chunks, isNotEmpty);
  });
}
