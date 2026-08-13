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

  // —— 复现 k3 等非标准端点的并行 tool_calls 拼接 bug ——
  // 端点在并行调用时流式分片未稳定提供递增 index（两个调用 index 都缺省=0），
  // 但每个分片各带独立 id。旧实现按 index 分桶会把两者拼成畸形 tool_call：
  //   name = "search_topicssearch_topics"
  //   arguments = {"keyword":"链式法则"}{"keyword":"隐函数存在定理"}
  // 修复后应按 id 分桶，产出两条独立的 ToolCall。
  test('并行 tool_calls 各带独立 id（index 缺省）→ 按 id 分桶，不拼接', () {
    final agg = SseToolCallAggregator();
    agg.onChunk({'choices': [{'delta': {'tool_calls': [
      {'index': 0, 'id': 'tool_a', 'function': {'name': 'search_topics', 'arguments': '{"keyword":"链式法则"}'}},
    ]}}]});
    agg.onChunk({'choices': [{'delta': {'tool_calls': [
      {'index': 0, 'id': 'tool_b', 'function': {'name': 'search_topics', 'arguments': '{"keyword":"隐函数存在定理"}'}},
    ]}}]});
    final result = agg.result;
    expect(result, hasLength(2));
    expect(result[0].id, 'tool_a');
    expect(result[0].name, 'search_topics');
    expect(result[0].arguments, '{"keyword":"链式法则"}');
    expect(result[1].id, 'tool_b');
    expect(result[1].name, 'search_topics');
    expect(result[1].arguments, '{"keyword":"隐函数存在定理"}');
  });

  // 标准 OpenAI 协议：id 只在首片出现，后续增量片只有 index（无 id）。
  // 修复后这些增量片应通过 index→id 映射归到正确桶，不丢失、不串桶。
  test('index→id 映射：首片带 id，后续增量片仅 index 时归到对应 id 桶', () {
    final agg = SseToolCallAggregator();
    // 两个并行调用，各自首片带 id + index 区分。
    agg.onChunk({'choices': [{'delta': {'tool_calls': [
      {'index': 0, 'id': 'tool_a', 'function': {'name': 'save_topic', 'arguments': '{"ti'}},
    ]}}]});
    agg.onChunk({'choices': [{'delta': {'tool_calls': [
      {'index': 1, 'id': 'tool_b', 'function': {'name': 'search_topics', 'arguments': '{"key'}},
    ]}}]});
    // 增量片：仅 index，无 id。应归到对应 id 桶。
    agg.onChunk({'choices': [{'delta': {'tool_calls': [
      {'index': 0, 'function': {'arguments': 'tle":"a"}'}},
      {'index': 1, 'function': {'arguments': 'word":"b"}'}},
    ]}}]});
    final result = agg.result;
    expect(result, hasLength(2));
    final byId = {for (final tc in result) tc.id: tc};
    expect(byId['tool_a']!.name, 'save_topic');
    expect(byId['tool_a']!.arguments, '{"title":"a"}');
    expect(byId['tool_b']!.name, 'search_topics');
    expect(byId['tool_b']!.arguments, '{"keyword":"b"}');
  });

  // 兜底：端点完全不带 id 时，退回按 index 分桶（保持旧行为，不回归）。
  test('无 id 时退回 index 分桶（兜底，不回归）', () {
    final agg = SseToolCallAggregator();
    agg.onChunk({'choices': [{'delta': {'tool_calls': [
      {'index': 0, 'function': {'name': 'get_topic', 'arguments': '{"id":1}'}},
      {'index': 1, 'function': {'name': 'get_mastery', 'arguments': '{"id":2}'}},
    ]}}]});
    final result = agg.result;
    expect(result, hasLength(2));
    expect(result[0].name, 'get_topic');
    expect(result[1].name, 'get_mastery');
  });
}
