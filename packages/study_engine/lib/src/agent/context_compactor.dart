import '../models/models.dart';

/// 上下文压缩：消息超过阈值时，保留首条 system + 最近 N 轮，其余丢弃。
/// （后续可替换为 LLM 摘要；地基阶段用简单裁剪。）
class ContextCompactor {
  final int threshold; // 消息条数阈值
  final int keepRecent; // 保留最近几条
  const ContextCompactor({this.threshold = 40, this.keepRecent = 20});

  bool needsCompaction(List<ChatMessage> messages) => messages.length > threshold;

  List<ChatMessage> compact(List<ChatMessage> messages) {
    if (!needsCompaction(messages)) return messages;
    final first = messages.firstWhere((m) => m.role == 'system', orElse: () => messages.first);
    final tail = messages.length > keepRecent ? messages.sublist(messages.length - keepRecent) : messages;
    return [first, ...tail.where((m) => m != first)];
  }
}
