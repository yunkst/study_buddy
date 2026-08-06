import '../models/models.dart';

/// 把流式响应中的 delta.tool_calls 按 index 聚合成完整 ToolCall。
class SseToolCallAggregator {
  final Map<int, _Partial> _partials = {};
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
        final index = tc['index'] as int? ?? 0;
        final p = _partials.putIfAbsent(index, () => _Partial());
        final fn = tc['function'] as Map?;
        if (fn != null) {
          if (fn['name'] is String) p.name = (p.name ?? '') + (fn['name'] as String);
          if (fn['arguments'] is String) p.args = (p.args ?? '') + (fn['arguments'] as String);
        }
        if (tc['id'] is String) p.id = tc['id'];
      }
    }
  }

  List<ToolCall> get result {
    final keys = _partials.keys.toList()..sort();
    return keys.map((k) {
      final p = _partials[k]!;
      return ToolCall(id: p.id ?? 'call_$k', name: p.name ?? '', arguments: p.args ?? '{}');
    }).toList();
  }
}

class _Partial {
  String? id;
  String? name;
  String? args;
}
