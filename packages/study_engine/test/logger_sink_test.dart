// packages/study_engine/test/logger_sink_test.dart
import 'package:test/test.dart';
import 'package:study_engine/study_engine.dart';

void main() {
  test('NullLoggerSink 是 const 且 log 不抛异常', () {
    const sink = NullLoggerSink();
    // 各级别 + 各参数组合,均应 no-op 不抛
    for (final level in LoggerLevel.values) {
      expect(
        () => sink.log(level, 'msg', category: 'ai', traceId: 't1', tags: const ['x']),
        returnsNormally,
      );
    }
  });

  test('NullLoggerSink 可作为 LoggerSink 使用', () {
    LoggerSink sink = const NullLoggerSink();
    sink.log(LoggerLevel.info, 'hello');
    expect(sink, isA<LoggerSink>());
  });

  test('LoggerLevel 枚举顺序为 debug<info<warning<error', () {
    expect(LoggerLevel.values, [LoggerLevel.debug, LoggerLevel.info, LoggerLevel.warning, LoggerLevel.error]);
  });

  test('NullLlmCallSink 是 const 且三方法不抛异常', () {
    const sink = NullLlmCallSink();
    final id = sink.onRequest(
      endpoint: 'https://x/v1/chat/completions',
      model: 'gpt',
      requestBody: '{}',
      isStreaming: true,
      traceId: 't1',
    );
    expect(id, '');
    expect(
      () => sink.onResponse(id, responseBody: 'resp', durationMs: 100, isSuccess: true),
      returnsNormally,
    );
    expect(
      () => sink.onError(id, errorMessage: 'boom', durationMs: 50),
      returnsNormally,
    );
  });

  test('NullLlmCallSink 可作为 LlmCallSink 使用', () {
    LlmCallSink sink = const NullLlmCallSink();
    expect(sink, isA<LlmCallSink>());
  });
}
