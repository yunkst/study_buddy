import '../models/models.dart';

/// 丢弃的中间轮次 → 一条摘要消息。实现侧可注入 LLM 摘要（completeText）；
/// 抛错会被 compactAsync 捕获并 fallback 到硬截断。
typedef SummarizerFn = Future<ChatMessage> Function(List<ChatMessage> dropped);

/// 上下文压缩：消息超过阈值时，保留首条 system + 最近 N 轮，其余处理。
///
/// 两档能力：
/// - [compact]：同步硬截断（保留 system + 最近 N，中间直接丢）。无 LLM 依赖，
///   `agent_base_test` 直接测它；未注入 [summarize] 时是唯一路径。
/// - [compactAsync]：注入 [summarize] 后，把被丢弃的中间轮次摘要成一条
///   消息回填（取代纯丢弃，避免 agent「失忆」——如忘了刚 save_topic 的 id）；
///   摘要失败 fallback 硬截断，不阻断主流程。
class ContextCompactor {
  final int threshold; // 消息条数阈值
  final int keepRecent; // 保留最近几条
  final SummarizerFn? summarize; // 可选：被丢弃轮次 → 摘要消息（默认 null=纯硬截断）

  const ContextCompactor({
    this.threshold = 40,
    this.keepRecent = 20,
    this.summarize,
  });

  bool needsCompaction(List<ChatMessage> messages) => messages.length > threshold;

  /// 同步硬截断：保留首条 system + 最近 [keepRecent] 条，其余丢弃。
  /// 不超阈值时返回原列表（同一引用，调用方可用 `same` 断言）。
  List<ChatMessage> compact(List<ChatMessage> messages) {
    if (!needsCompaction(messages)) return messages;
    final first =
        messages.firstWhere((m) => m.role == 'system', orElse: () => messages.first);
    final tail = messages.length > keepRecent
        ? messages.sublist(messages.length - keepRecent)
        : messages;
    return [first, ...tail.where((m) => m != first)];
  }

  /// 异步压缩：注入 [summarize] 时把中间轮次摘要回填；否则等价 [compact]。
  /// 摘要抛错 → fallback 硬截断（返回同 [compact]），主流程不受影响。
  Future<List<ChatMessage>> compactAsync(List<ChatMessage> messages) async {
    if (!needsCompaction(messages)) return messages;
    final first =
        messages.firstWhere((m) => m.role == 'system', orElse: () => messages.first);
    final tail = messages.length > keepRecent
        ? messages.sublist(messages.length - keepRecent)
        : messages;
    final keepSet = <ChatMessage>{first, ...tail}; // identity 集合（未重载 ==）
    final dropped = messages.where((m) => !keepSet.contains(m)).toList();
    final fn = summarize;
    if (fn == null || dropped.isEmpty) return [first, ...tail];
    try {
      final summaryMsg = await fn(dropped);
      return [first, summaryMsg, ...tail];
    } catch (_) {
      // 摘要失败（网络/解析）：降级为硬截断，避免 LLM 抖动中断整个 agent 流。
      return [first, ...tail];
    }
  }
}
