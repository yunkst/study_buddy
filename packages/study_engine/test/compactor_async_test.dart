import 'dart:io';

import 'package:test/test.dart';
import 'package:study_engine/study_engine.dart';

/// 辅助：构造一条 token 量明确的消息（content = tag + 填充，约 (len/4) token）。
ChatMessage _msg(String role, String tag, {int pad = 40}) =>
    ChatMessage(role: role, content: '$tag${'x' * pad}');

/// 上下文压缩（compactAsync 摘要回填）与工具输出截断测试。
void main() {
  group('ContextCompactor.compactAsync', () {
    test('未注入 summarize 时等价同步 compact（纯硬截断）', () async {
      // 每条 user ≈ 11 token；6 条 ≈ 66 + sys。trigger=30 触发，target=22 留约 2 条。
      const c = ContextCompactor(triggerTokens: 30, targetTokens: 22);
      final msgs = [
        _msg('system', 'sys'),
        for (var i = 0; i < 6; i++) _msg('user', 'm$i'),
      ];
      final out = await c.compactAsync(msgs);
      expect((out.first.content as String).startsWith('sys'), isTrue);
      expect(out.length, lessThan(msgs.length));
      expect((out.last.content as String).startsWith('m5'), isTrue);
    });

    test('不超阈值返回同一引用', () async {
      const c = ContextCompactor(triggerTokens: 100000, targetTokens: 10);
      final msgs = [
        const ChatMessage(role: 'system', content: 'sys'),
        const ChatMessage(role: 'user', content: 'hi'),
      ];
      expect(await c.compactAsync(msgs), same(msgs));
    });

    test('注入 summarize：中间轮次摘要回填为一条 system 消息', () async {
      final c = ContextCompactor(
        triggerTokens: 30,
        targetTokens: 22,
        summarize: (dropped) async {
          // 断言被丢弃的是中间消息（非 system、非最近保留区）
          final contents = dropped.map((m) => m.content as String).toList();
          expect(contents.any((s) => s.startsWith('sys')), isFalse);
          expect(contents.any((s) => s.startsWith('m5')), isFalse);
          expect(contents.any((s) => s.startsWith('m0')), isTrue); // 确有丢弃
          return const ChatMessage(role: 'system', content: '【摘要】已保存知识点 id=42');
        },
      );
      final msgs = [
        _msg('system', 'sys'),
        for (var i = 0; i < 6; i++) _msg('user', 'm$i'),
      ];
      final out = await c.compactAsync(msgs);
      // system + 摘要 + 最近保留区
      expect((out.first.content as String).startsWith('sys'), isTrue);
      expect(out.any((m) => (m.content as String) == '【摘要】已保存知识点 id=42'), isTrue);
      expect((out.last.content as String).startsWith('m5'), isTrue);
    });

    test('摘要抛错时 fallback 硬截断，不阻断', () async {
      final c = ContextCompactor(
        triggerTokens: 30,
        targetTokens: 22,
        summarize: (_) async => throw Exception('LLM 挂了'),
      );
      final msgs = [
        _msg('system', 'sys'),
        for (var i = 0; i < 6; i++) _msg('user', 'm$i'),
      ];
      final out = await c.compactAsync(msgs);
      expect((out.first.content as String).startsWith('sys'), isTrue);
      expect(out.length, lessThan(msgs.length)); // 硬截断结果
      expect((out.last.content as String).startsWith('m5'), isTrue);
    });
  });

  group('truncateToolOutput', () {
    test('tmpDir 为 null 时不截断（测试默认）', () {
      final result = truncateToolOutput('x' * 10000, maxChars: 100);
      expect(result, 'x' * 10000);
    });

    test('未超长时不截断', () {
      final dir = Directory.systemTemp.createTempSync('agent-tool-test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final result = truncateToolOutput('short', maxChars: 100, tmpDir: dir.path);
      expect(result, 'short');
    });

    test('超长时落临时文件并返回指针 + 预览', () {
      final dir = Directory.systemTemp.createTempSync('agent-tool-test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final long = '数据' * 5000; // 10000 字
      final result = truncateToolOutput(long, maxChars: 100, tmpDir: dir.path);
      expect(result, contains('已写入临时文件'));
      expect(result, contains('前 100 字预览'));
      expect(result, contains('数据数据')); // 前缀
      expect(result.length, lessThan(300));
      // 临时文件真实存在且内容完整
      final path = RegExp(r'agent-tool-\d+\.txt').firstMatch(result)?.group(0);
      expect(path, isNotNull);
      final files = dir.listSync().whereType<File>().toList();
      expect(files, hasLength(1));
      expect(files.single.readAsStringSync(), long);
    });
  });
}
