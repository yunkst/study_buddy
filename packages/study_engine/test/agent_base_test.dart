import 'package:test/test.dart';
import 'package:study_engine/study_engine.dart';

void main() {
  test('超过阈值时裁剪并保留 system + 最近 N 条', () {
    final c = const ContextCompactor(threshold: 5, keepRecent: 2);
    final msgs = <ChatMessage>[
      const ChatMessage(role: 'system', content: 'sys'),
      for (var i = 0; i < 6; i++) ChatMessage(role: 'user', content: 'u$i'),
    ];
    final out = c.compact(msgs);
    expect(out.first.role, 'system');
    expect(out.length, lessThanOrEqualTo(msgs.length));
    expect(out.any((m) => (m.content as String) == 'u5'), isTrue);
  });

  test('未超阈值不裁剪', () {
    final c = const ContextCompactor(threshold: 100);
    final msgs = [const ChatMessage(role: 'user', content: 'x')];
    expect(c.compact(msgs), same(msgs));
  });
}
