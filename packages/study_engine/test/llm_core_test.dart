import 'dart:async';
import 'package:test/test.dart';
import 'package:study_engine/study_engine.dart';

/// 假客户端：吐预设的 SSE data 行。
class _FakeClient implements LlmHttpClient {
  _FakeClient(this.lines);
  final List<String> lines;
  @override
  Stream<String> postStream(Uri uri, Map<String, String> headers, Map<String, Object?> body) {
    return Stream.fromIterable(lines);
  }
}

void main() {
  test('chatStreamWithTools 推文本增量并在末包给工具调用', () async {
    final cfg = LlmConfig(
      name: 't', apiUrl: 'https://api.example.com/v1', apiKey: 'k', model: 'm', createdAt: DateTime.now());
    final lines = [
      '{"choices":[{"delta":{"content":"已"}}]}',
      '{"choices":[{"delta":{"content":"保存"}}]}',
      '{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"save_topic","arguments":"{}"}}]}}]}',
    ];
    final provider = LlmProvider(config: cfg, client: _FakeClient(lines));
    final chunks = await provider.chatStreamWithTools(messages: [], tools: []).toList();
    final texts = chunks.where((c) => c.toolCalls == null).map((c) => c.textDelta).join();
    expect(texts, '已保存');
    final endChunk = chunks.lastWhere((c) => c.toolCalls != null);
    expect(endChunk.toolCalls!.first.name, 'save_topic');
  });
}
