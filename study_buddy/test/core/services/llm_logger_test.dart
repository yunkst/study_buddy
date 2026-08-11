// study_buddy/test/core/services/llm_logger_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:study_buddy/core/services/llm_logger/llm_logger.dart';
import 'package:study_buddy/core/services/llm_logger/llm_call_record.dart';

void main() {
  setUp(() {
    LlmLogger.resetForTesting();
  });

  test('onRequest→onResponse 关联同一 id 并落内存缓存', () async {
    await LlmLogger.instance.initializeForTest();
    final id = LlmLogger.instance.onRequest(
      endpoint: 'https://x/v1/chat/completions',
      model: 'gpt',
      requestBody: '{"model":"gpt","messages":[]}',
      isStreaming: true,
      traceId: 'trace-1',
    );
    LlmLogger.instance.onResponse(id,
        responseBody: '{"choices":[]}', durationMs: 120, isSuccess: true, totalTokens: 42);

    final recent = await LlmLogger.instance.getRecent(limit: 10);
    expect(recent, hasLength(1));
    expect(recent.first.id, id);
    expect(recent.first.model, 'gpt');
    expect(recent.first.isSuccess, isTrue);
    expect(recent.first.totalTokens, 42);
    expect(recent.first.durationMs, 120);
    expect(recent.first.traceId, 'trace-1');
  });

  test('previewText 从 requestBody 提取 content', () {
    final r = LlmCallRecord(
      id: '1', timestamp: DateTime.utc(2026, 8, 11),
      endpoint: 'e', model: 'm', isStreaming: true,
      requestBody: '{"messages":[{"content":"你好世界"}]}',
      isSuccess: true,
    );
    expect(r.previewText, contains('你好世界'));
  });

  test('toJson/fromJson 往返(含 traceId)', () {
    final r = LlmCallRecord(
      id: '1', timestamp: DateTime.utc(2026, 8, 11),
      endpoint: 'e', model: 'm', isStreaming: false,
      requestBody: '{}', responseBody: '{"x":1}',
      durationMs: 5, isSuccess: true,
      promptTokens: 10, completionTokens: 20, totalTokens: 30,
      traceId: 't9',
    );
    final restored = LlmCallRecord.fromJson(r.toJson());
    expect(restored.id, '1');
    expect(restored.traceId, 't9');
    expect(restored.totalTokens, 30);
  });

  test('durationText 格式化', () {
    final r = LlmCallRecord(
      id: '1', timestamp: DateTime.utc(2026, 8, 11),
      endpoint: '', isStreaming: false, requestBody: '', durationMs: 800, isSuccess: true,
    );
    expect(r.durationText, '800ms');
    final r2 = LlmCallRecord(
      id: '2', timestamp: DateTime.utc(2026, 8, 11),
      endpoint: '', isStreaming: false, requestBody: '', durationMs: 1500, isSuccess: true,
    );
    expect(r2.durationText, '1.5s');
  });
}
