// 回归测试：k3 并行 tool_calls 分桶（index 复用 + 增量片无 id）不串桶。
//
// 背景（线上日志 agent-1786687011490 实证）：
// 模型并行调用 3 次 tool（如 link_topics from→to 9/10/11），k3 流式分片中
// index 全部缺省（0），各首片带独立 id，但后续增量分片**不带 id**。
// 旧逻辑用 _indexToId[index] 定向无 id 增量片 → 全部串到第一个 id 桶：
//   tool_C0I...: {8→9}{8→10}   ← 两个 JSON 拼接（jsonDecode 失败 → 工具被跳过）
//   tool_Hm2...: ""            ← 空串（同样跳过）
//   tool_qAa...: {8→11}        ← 仅此桶正确
// 聚合产出与线上日志完全一致。修复后每个桶各自拿到完整、不拼接、非空的参数。
import 'dart:convert';
import 'package:study_engine/study_engine.dart';
import 'package:test/test.dart';

void main() {
  /// k3 风格的流式序列：
  /// - index 恒为 0（并行调用不缺省 index 递增）
  /// - 首个分片带 id + name + arguments 首片
  /// - 中间可能有带 id 但 arguments 为空的过渡分片
  /// - 关键增量分片不带 id
  void feed(SseToolCallAggregator agg, List<Map<String, dynamic>> tcs) {
    for (final tc in tcs) {
      agg.onChunk({
        'choices': [
          {
            'delta': {'tool_calls': [tc]},
          },
        ],
      });
    }
  }

  test('并行 tool_calls：index 复用 + 增量片无 id → 不拼接、各桶参数完整', () {
    final agg = SseToolCallAggregator();
    feed(agg, [
      {
        'index': 0,
        'id': 'tool_C0I...',
        'function': {'name': 'link_topics', 'arguments': '{"from":8,"to":9,"type":"related"}'},
      },
      {
        'index': 0,
        'id': 'tool_Hm2...',
        'function': {'name': 'link_topics', 'arguments': ''},
      },
      // 关键增量片：无 id，index=0。旧逻辑串进 tool_C0I 桶造成拼接。
      {
        'index': 0,
        'function': {'arguments': '{"from":8,"to":10,"type":"related"}'},
      },
      {
        'index': 0,
        'id': 'tool_qAa...',
        'function': {'name': 'link_topics', 'arguments': '{"from":8,"to":11,"type":"related"}'},
      },
    ]);

    final result = agg.result;
    expect(result, hasLength(3), reason: '并行调用应产出 3 条独立 ToolCall');
    final byId = {for (final t in result) t.id: t};

    expect(byId['tool_C0I...']!.arguments, '{"from":8,"to":9,"type":"related"}',
        reason: 'C0I 桶不应被并入其他调用的增量片（不得拼接）');
    expect(byId['tool_Hm2...']!.arguments, '{"from":8,"to":10,"type":"related"}',
        reason: 'Hm2 桶应收到紧跟其后的无 id 增量片（修复前为空串）');
    expect(byId['tool_qAa...']!.arguments, '{"from":8,"to":11,"type":"related"}');

    // 每条 arguments 都必须是可独立 jsonDecode 的单个合法 JSON 对象
    for (final t in result) {
      final decoded = jsonDecode(t.arguments);
      expect(decoded, isA<Map<String, dynamic>>(),
          reason: '${t.id} 的 arguments 必须是单个合法 JSON，实际: ${t.arguments}');
    }
  });

  test('存在 index 递增的标准协议调用时，index→id 映射不受失效检测影响', () {
    final agg = SseToolCallAggregator();
    // 标准 OpenAI 协议：两个并行调用 index 递增，首片带 id，增量片仅带 index。
    feed(agg, [
      {'index': 0, 'id': 'tool_a', 'function': {'name': 'save_topic', 'arguments': '{"ti'}},
      {'index': 1, 'id': 'tool_b', 'function': {'name': 'search_topics', 'arguments': '{"key'}},
      {'index': 0, 'function': {'arguments': 'tle":"a"}'}},
      {'index': 1, 'function': {'arguments': 'word":"b"}'}},
    ]);
    final result = agg.result;
    expect(result, hasLength(2));
    final byId = {for (final t in result) t.id: t};
    expect(byId['tool_a']!.arguments, '{"title":"a"}');
    expect(byId['tool_b']!.arguments, '{"keyword":"b"}');
  });
}