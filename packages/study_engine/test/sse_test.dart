import 'package:test/test.dart';
import 'package:study_engine/study_engine.dart';

void main() {
  test('聚合分片 tool_calls delta', () {
    final agg = SseToolCallAggregator();
    agg.onChunk({'choices': [{'delta': {'content': '你好'}}]});
    agg.onChunk({'choices': [{'delta': {'tool_calls': [
      {'index': 0, 'id': 'call_a', 'function': {'name': 'save_top', 'arguments': '{"ti'}},
    ]}}]});
    agg.onChunk({'choices': [{'delta': {'tool_calls': [
      {'index': 0, 'function': {'name': 'ic', 'arguments': 'tle":"t"}'}},
    ]}}]});
    agg.onChunk({'choices': [{'delta': {}}]});
    expect(agg.text, '你好');
    expect(agg.hasToolCalls, isTrue);
    expect(agg.result, hasLength(1));
    final tc = agg.result.first;
    expect(tc.name, 'save_topic');
    expect(tc.arguments, '{"title":"t"}');
    expect(tc.id, 'call_a');
  });

  test('纯文本无工具调用', () {
    final agg = SseToolCallAggregator();
    agg.onChunk({'choices': [{'delta': {'content': '完成'}}]});
    expect(agg.hasToolCalls, isFalse);
    expect(agg.text, '完成');
  });
}
