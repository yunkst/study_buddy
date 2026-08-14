import '../models/models.dart';

/// 聚合结果 tool_call id 归一化 —— 根治 400 tool_call_id is not found 的源头。
///
/// 背景: agent 把 LLM 返回的 tool_calls 原样回灌 msgs(为让 LLM 看到失败以便自纠)。
/// 但若某个 ToolCall.id 为空/缺失(SSE 偶发),assistant 消息 `tool_calls[].id` 为空,
/// 后续 tool 消息 `tool_call_id` 也被赋空/缺失,网关校验找不到 -> 400
/// "tool_call_id  is not found"(两个空格 = 空值)。
///
/// 本函数在聚合完成后、构造 assistant 消息**之前**调用:把 id 为空/重复的
/// ToolCall 统一替换为 session-stable 占位 id `call_recovered_N`,保证:
/// 1) assistant.tool_calls[].id 全部非空且唯一;
/// 2) 后续 tool 消息用同一 id,协议严格成对。
List<ToolCall> normalizeToolCallIds(
  List<ToolCall> agg, {
  Set<String> usedIds = const {},
}) {
  var maxN = -1;
  for (final id in usedIds) {
    final match = RegExp(r'^call_recovered_(\d+)$').firstMatch(id);
    if (match != null) {
      final n = int.parse(match.group(1)!);
      if (n > maxN) maxN = n;
    }
  }
  final seen = <String>{...usedIds};
  var nextN = maxN + 1;
  return agg.map((t) {
    if (t.id.isNotEmpty && !seen.contains(t.id)) {
      seen.add(t.id);
      return t;
    }
    // 空 id 或重复 id → 分配未占用的 call_recovered_N
    String newId;
    do {
      newId = 'call_recovered_$nextN';
      nextN++;
    } while (seen.contains(newId));
    seen.add(newId);
    return t.copyWith(id: newId);
  }).toList();
}