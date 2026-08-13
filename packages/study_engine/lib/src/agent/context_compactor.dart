import '../models/models.dart';

/// 丢弃的中间轮次 → 一条摘要消息。实现侧可注入 LLM 摘要（completeText）；
/// 抛错会被 compactAsync 捕获并 fallback 到硬截断。
typedef SummarizerFn = Future<ChatMessage> Function(List<ChatMessage> dropped);

/// 上下文窗口 token 数的默认值（1M）。
///
/// 1M 是当前主流长上下文模型（如 Gemini 2.5 Pro / DeepSeek V3 等）的上下文上限。
/// study_engine 不假设模型一定支持这么长——[ContextCompactor] 仅按 token 触发压缩，
/// 具体配多大窗口由 App 层按 `llm_config` 的模型决定（构造时覆盖即可）。
const int kDefaultContextTokens = 1000000;

/// 默认触发阈值（窗口的 ~85%，给输出与系统开销留余地）。
const int kDefaultTriggerTokens = (kDefaultContextTokens * 85) ~/ 100; // ≈850K

/// 默认压缩后保留量（窗口的 ~1/3）。
const int kDefaultTargetTokens = (kDefaultContextTokens * 33) ~/ 100; // ≈330K

/// CJK / 全角字符的码点区间（用于 token 估算时与 ASCII 区分）。
///
/// 覆盖不必精确，量级对即可。包含：谚文、CJK 标点与假名、CJK 扩展A、
/// CJK 基本区、谚文音节、CJK 兼容、全角符号、CJK 扩展B/C/D。
const List<(int, int)> _cjkRanges = [
  (0x1100, 0x11FF), // 谚文 Jamo
  (0x3000, 0x30FF), // CJK 标点 / 假名
  (0x3400, 0x4DBF), // CJK 扩展 A
  (0x4E00, 0x9FFF), // CJK 基本区
  (0xAC00, 0xD7AF), // 谚文音节
  (0xF900, 0xFAFF), // CJK 兼容表意
  (0xFF00, 0xFFEF), // 全角符号
  (0x20000, 0x2A6DF), // CJK 扩展 B
  (0x2A700, 0x2FA1F), // CJK 扩展 C/D
];

bool _isCjk(int code) {
  for (final r in _cjkRanges) {
    if (code >= r.$1 && code <= r.$2) return true;
  }
  return false;
}

/// 把一条消息粗估成 token 数（偏保守以利触发压缩）。
///
/// Dart 无官方 tokenizer（tiktoken 无 Dart 实现），这里用字符维度估算：
/// - ASCII / 半角：约 4 char/token；
/// - CJK / 全角：约 1 char ≈ 1.5 token（中文 token 化通常一字 ~1-2 token）。
/// 1M 量级下几十百分比偏差不影响「该不该压缩」的决策，故刻意保守——高估一点
/// 比漏压更安全（漏压直接 `context length exceeded`）。工具调用的 name/arguments
/// JSON 同样计入。
int estimateMessageTokens(ChatMessage m) {
  final text = switch (m.content) {
    String s => s,
    List<ContentPart> parts =>
      parts.whereType<TextPart>().map((p) => p.text).join(),
    _ => '',
  };
  var cjk = 0;
  for (final code in text.runes) {
    if (_isCjk(code)) cjk++;
  }
  final ascii = text.length - cjk;
  final baseTokens = (ascii / 4 + cjk * 1.5).ceil();
  final toolTokens = m.toolCalls == null
      ? 0
      : m.toolCalls!.fold<int>(
          0, (a, t) => a + t.name.length + t.arguments.length + 24);
  return (baseTokens + toolTokens).clamp(1, 1 << 30);
}

int _estimateListTokens(Iterable<ChatMessage> msgs) {
  var sum = 0;
  for (final m in msgs) {
    sum += estimateMessageTokens(m);
  }
  return sum;
}

/// 上下文压缩：token 超阈值时，保留首条 system + 最近若干条（按 token 量回扫），
/// 中间处理。
///
/// 阈值是 **token 量**（不再是消息条数）——条数与 token 无固定对应（一条工具结果
/// 可能 2 万字），按条数压缩既可能在短上下文时白白裁剪，又可能在长工具输出时
/// 漏压导致 `context length exceeded`。
///
/// 两档能力：
/// - [compact]：同步硬截断（保留 system + 最近 targetTokens 量，中间直接丢）。无 LLM
///   依赖，`agent_base_test` 直接测它；未注入 [summarize] 时是唯一路径。
/// - [compactAsync]：注入 [summarize] 后，把被丢弃的中间轮次摘要成一条消息回填
///   （取代纯丢弃，避免 agent「失忆」——如忘了刚 save_topic 的 id）；摘要失败
///   fallback 硬截断，不阻断主流程。
///
/// 切割点保证 **不拆散 assistant(tool_calls) 与其 tool 结果消息对**——否则会产生
/// 孤儿 tool 消息（role=tool 但无对应 assistant tool_calls），发给 LLM 会被网关
/// 拒为 `400 tool_call_id is not found`。
class ContextCompactor {
  /// 触发压缩的 token 阈值。历史 token 估算超过此值才压缩。
  /// 默认取上下文窗口（1M）的 ~85%，给输出与系统开销留余地。
  final int triggerTokens;

  /// 压缩后保留的「最近 token 量」目标。从尾部按 token 回扫保留，不保证恰好等于
  /// 该值（会向上对齐到一个完整的消息轮），但不少于。
  final int targetTokens;

  final SummarizerFn? summarize; // 可选：被丢弃轮次 → 摘要消息（默认 null=纯硬截断）

  const ContextCompactor({
    this.triggerTokens = kDefaultTriggerTokens,
    this.targetTokens = kDefaultTargetTokens,
    this.summarize,
  });

  /// 历史是否需要压缩：按 token 估算超过 [triggerTokens]。
  bool needsCompaction(List<ChatMessage> messages) =>
      _estimateListTokens(messages) > triggerTokens;

  /// 同步硬截断：保留首条 system + 最近「约 [targetTokens] token」的尾部，
  /// 中间丢弃。不超阈值时返回原列表（同一引用，调用方可用 `same` 断言）。
  List<ChatMessage> compact(List<ChatMessage> messages) {
    if (!needsCompaction(messages)) return messages;
    final first = _findFirst(messages);
    final cut = _findCutIndex(messages, first);
    final tail = messages.sublist(cut);
    return [first, ...tail.where((m) => m != first)];
  }

  /// 异步压缩：注入 [summarize] 时把中间轮次摘要回填；否则等价 [compact]。
  /// 摘要抛错 → fallback 硬截断（返回同 [compact]），主流程不受影响。
  Future<List<ChatMessage>> compactAsync(List<ChatMessage> messages) async {
    if (!needsCompaction(messages)) return messages;
    final first = _findFirst(messages);
    final cut = _findCutIndex(messages, first);
    final tail = messages.sublist(cut);
    final keptTail = tail.where((m) => m != first).toList();
    final keptSet = <ChatMessage>{first, ...keptTail}; // identity 集合（未重载 ==）
    final dropped = messages.where((m) => !keptSet.contains(m)).toList();
    final fn = summarize;
    if (fn == null || dropped.isEmpty) return [first, ...keptTail];
    try {
      final summaryMsg = await fn(dropped);
      return [first, summaryMsg, ...keptTail];
    } catch (_) {
      // 摘要失败（网络/解析）：降级为硬截断，避免 LLM 抖动中断整个 agent 流。
      return [first, ...keptTail];
    }
  }

  /// 定位首条 system（无则首条消息），单独抽出便于复用与测试。
  ChatMessage _findFirst(List<ChatMessage> messages) =>
      messages.firstWhere((m) => m.role == 'system', orElse: () => messages.first);

  /// 从尾部向前累积 token，直到达到 [targetTokens]，再回退到「成对边界」，
  /// 返回 tail 的起始 index。
  ///
  /// 成对边界：若 messages[cut] 是 role==tool 的消息（孤儿风险——它的 assistant
  /// 在 cut 之前被切掉），就把 cut 再前移，直到 messages[cut] 不是 tool 消息。
  /// 这样保留区里不会出现无主的 tool 结果。
  int _findCutIndex(List<ChatMessage> messages, ChatMessage first) {
    final firstIdx = messages.indexOf(first);
    var sum = 0;
    var i = messages.length;
    while (i > firstIdx + 1) {
      if (sum >= targetTokens) break;
      sum += estimateMessageTokens(messages[i - 1]);
      i--;
    }
    // 成对边界修正：cut 落在 tool 消息上时前移到它对应 assistant 之前，
    // 避免保留区出现孤儿 tool 消息。
    while (i < messages.length && messages[i].role == 'tool') {
      i--;
    }
    if (i < firstIdx + 1) i = firstIdx + 1; // 至少保留 system 之外一点
    return i;
  }
}
