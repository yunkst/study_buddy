import 'package:test/test.dart';
import 'package:study_engine/study_engine.dart';

/// 辅助：构造一条 token 量明确的消息。
/// content 用 [tag] + 填充，使每条 token 约为 (len/4)。便于精确控制阈值。
ChatMessage _msg(String role, String tag, {int pad = 40}) =>
    ChatMessage(role: role, content: '$tag${'x' * pad}');

void main() {
  test('超过 token 阈值时裁剪并保留 system + 最近若干条', () {
    // 每条 user ≈ (4+40)/4 ≈ 11 token；6 条 ≈ 66 token + sys。
    // triggerTokens=30 触发；targetTokens=22 保留最近约 2 条。
    final c = const ContextCompactor(triggerTokens: 30, targetTokens: 22);
    final msgs = <ChatMessage>[
      _msg('system', 'sys'),
      for (var i = 0; i < 6; i++) _msg('user', 'u$i'),
    ];
    final out = c.compact(msgs);
    expect(out.first.role, 'system');
    expect(out.length, lessThan(msgs.length)); // 确实压缩了
    expect((out.last.content as String).startsWith('u5'), isTrue); // 保留最近
  });

  test('未超 token 阈值不裁剪（返回同一引用）', () {
    final c = const ContextCompactor(triggerTokens: 100000);
    final msgs = [const ChatMessage(role: 'user', content: 'x')];
    expect(c.compact(msgs), same(msgs));
  });

  test('estimateMessageTokens：ASCII 与 CJK 各按各自系数估算', () {
    final ascii = estimateMessageTokens(ChatMessage(role: 'user', content: 'a' * 40));
    final cjk = estimateMessageTokens(ChatMessage(role: 'user', content: '中' * 10));
    // ASCII 40 char ≈ 10 token；CJK 10 char ≈ 15 token
    expect(ascii, closeTo(10, 2));
    expect(cjk, greaterThan(ascii));
  });

  group('成对边界：不拆散 assistant(tool_calls) 与 tool 结果', () {
    // 构造一条带 tool_calls 的 assistant（无填充，靠 toolCalls 的 +24 撑 token）
    // + 对应 tool 消息（带填充，token 较大）。这样回扫会在 tool 消息处累积达标，
    // 切割点天然落在 tool 上——正是要被修正的孤儿场景。
    ChatMessage asst(int n) => ChatMessage(
          role: 'assistant',
          content: 'c$n',
          toolCalls: [ToolCall(id: 'c$n', name: 'noop', arguments: '{}')],
        );
    ChatMessage tool(int n) =>
        ChatMessage(role: 'tool', content: 'r$n${'y' * 40}', toolCallId: 'c$n');

    test('保留区不出现孤儿 tool 消息（tool_call_id 无对应 assistant）', () {
      // 3 对 + system + 末尾 user；targetTokens 设到「恰好切在第 2 对的 tool 上」。
      final c = const ContextCompactor(triggerTokens: 1, targetTokens: 15);
      final msgs = <ChatMessage>[
        const ChatMessage(role: 'system', content: 'sys'),
        asst(0),
        tool(0),
        asst(1),
        tool(1),
        asst(2),
        tool(2),
        const ChatMessage(role: 'user', content: 'latest'),
      ];
      final out = c.compact(msgs);
      // 断言：保留区里每条 tool 消息的 tool_call_id 都能在保留区的某条
      // assistant.toolCalls 里找到——无孤儿。
      final assistantIds = <String>{};
      for (final m in out) {
        if (m.toolCalls != null) {
          assistantIds.addAll(m.toolCalls!.map((t) => t.id));
        }
      }
      expect(out.any((m) => m.toolCallId != null), isTrue, reason: '测试应保留了 tool 消息');
      for (final m in out) {
        if (m.toolCallId != null) {
          expect(assistantIds, contains(m.toolCallId),
              reason: '孤儿 tool 消息: ${m.toolCallId}');
        }
      }
    });
  });
}
