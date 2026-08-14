// normalizeToolCallIds 单元测试:聚合结果 tool_call id 归一化。
import 'package:study_engine/study_engine.dart';
import 'package:test/test.dart';

void main() {
  test('空 id 的 ToolCall 被分配 call_recovered_N 占位 id', () {
    final in_ = [
      const ToolCall(id: '', name: 'link_topics', arguments: '{}'),
      const ToolCall(id: 'tool_a', name: 'x', arguments: '{}'),
    ];
    final out = normalizeToolCallIds(in_);
    expect(out[0].id, startsWith('call_recovered_'),
        reason: '空 id 应被归一化为占位 id');
    expect(out[0].id, isNot(''), reason: '归一化后 id 不可为空');
    expect(out[1].id, 'tool_a', reason: '非空 id 保持不变');
    // 唯一性
    final ids = out.map((t) => t.id).toSet();
    expect(ids, hasLength(2));
  });

  test('重复 id 的 ToolCall 被重新分配,保证唯一', () {
    final in_ = [
      const ToolCall(id: 'tool_a', name: 'x', arguments: '{"a":1}'),
      const ToolCall(id: 'tool_a', name: 'y', arguments: '{"b":2}'), // 重复
    ];
    final out = normalizeToolCallIds(in_);
    final ids = out.map((t) => t.id).toList();
    expect(ids.toSet(), hasLength(2), reason: '重复 id 必须被拆开');
    expect(out[0].id, 'tool_a');
    expect(out[1].id, isNot('tool_a'));
    expect(out[1].id, startsWith('call_recovered_'));
  });

  test('usedIds 已含 call_recovered_0 时从 1 开始,避免冲突', () {
    final in_ = [const ToolCall(id: '', name: 'x', arguments: '{}')];
    final out = normalizeToolCallIds(in_, usedIds: {'call_recovered_0'});
    expect(out.single.id, 'call_recovered_1');
  });

  test('仅空 id 时依次分配 call_recovered_0/1/2', () {
    final in_ = [
      const ToolCall(id: '', name: 'a', arguments: '{}'),
      const ToolCall(id: '', name: 'b', arguments: '{}'),
      const ToolCall(id: '', name: 'c', arguments: '{}'),
    ];
    final out = normalizeToolCallIds(in_);
    expect(out.map((t) => t.id), ['call_recovered_0', 'call_recovered_1', 'call_recovered_2']);
  });

  test('name/arguments 保持不变(仅换 id)', () {
    final in_ = [
      const ToolCall(id: '', name: 'link_topics', arguments: '{"from":8,"to":9}'),
    ];
    final out = normalizeToolCallIds(in_);
    expect(out.single.name, 'link_topics');
    expect(out.single.arguments, '{"from":8,"to":9}');
  });
}