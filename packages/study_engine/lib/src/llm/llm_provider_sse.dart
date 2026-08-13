import '../models/models.dart';

/// 把流式响应中的 delta.tool_calls 按分片聚合成完整 ToolCall。
///
/// 分桶策略（修复非标准端点的并行调用拼接 bug）：
/// - **优先按 id 分桶**：分片带唯一 id 时以 id 为桶键。并行 tool_calls 即使
///   index 缺省/复用（如 k3 端点），只要各带独立 id 就能正确分开。
/// - **index→id 映射**：标准 OpenAI 协议中 id 只在首片出现、后续增量片仅带 index；
///   通过 index→id 映射把增量片归到对应 id 桶。
/// - **兜底按 index 分桶**：端点完全不带 id 时退回旧行为，保证不回归。
class SseToolCallAggregator {
  /// 桶键：优先用 id（String），无 id 时用 index（int）。
  final Map<Object, _Partial> _partials = {};

  /// index → 首次登记到的 id 映射，供「仅 index 的增量片」定位 id 桶。
  final Map<int, String> _indexToId = {};

  /// 桶键首次出现顺序，保证 result 输出稳定（不依赖 Map 迭代序）。
  final List<Object> _order = [];

  final StringBuffer _text = StringBuffer();

  bool get hasToolCalls => _partials.isNotEmpty;
  String get text => _text.toString();

  /// 处理一个 SSE chunk 的 JSON 解析结果。
  void onChunk(Map<String, dynamic> chunk) {
    final choices = chunk['choices'] as List?;
    if (choices == null || choices.isEmpty) return;
    final delta = (choices.first as Map)['delta'] as Map?;
    if (delta == null) return;
    final content = delta['content'];
    if (content is String && content.isNotEmpty) _text.write(content);
    final toolCalls = delta['tool_calls'];
    if (toolCalls is List) {
      for (final tc in toolCalls) {
        if (tc is! Map) continue;
        final id = tc['id'];
        final index = tc['index'] as int? ?? 0;
        // 登记 index→id（仅当该 index 首次见到 id；后续同 index 的不同 id 各开新桶）。
        if (id is String) _indexToId.putIfAbsent(index, () => id);
        // 确定桶键：
        // 1) 带 id → 以 id 为键（k3 并行调用即使 index 复用也能分开）；
        // 2) 仅 index 且已登记 id → 归到对应 id 桶（标准协议增量片）；
        // 3) 否则退回 index（端点完全无 id 的兜底）。
        final Object key;
        if (id is String) {
          key = id;
        } else if (_indexToId.containsKey(index)) {
          key = _indexToId[index]!;
        } else {
          key = index;
        }
        final p = _partials.putIfAbsent(key, () {
          _order.add(key);
          return _Partial();
        });
        final fn = tc['function'] as Map?;
        if (fn != null) {
          if (fn['name'] is String) p.name = (p.name ?? '') + (fn['name'] as String);
          if (fn['arguments'] is String) p.args = (p.args ?? '') + (fn['arguments'] as String);
        }
        if (id is String) p.id = id;
      }
    }
  }

  List<ToolCall> get result {
    return _order.map((key) {
      final p = _partials[key]!;
      return ToolCall(id: p.id ?? 'call_$key', name: p.name ?? '', arguments: p.args ?? '{}');
    }).toList();
  }
}

class _Partial {
  String? id;
  String? name;
  String? args;
}
