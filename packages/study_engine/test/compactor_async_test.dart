import 'dart:io';

import 'package:test/test.dart';
import 'package:study_engine/study_engine.dart';

/// 上下文压缩（compactAsync 摘要回填）与工具输出截断测试。
void main() {
  group('ContextCompactor.compactAsync', () {
    test('未注入 summarize 时等价同步 compact（纯硬截断）', () async {
      const c = ContextCompactor(threshold: 5, keepRecent: 2);
      final msgs = [
        const ChatMessage(role: 'system', content: 'sys'),
        for (var i = 0; i < 6; i++) ChatMessage(role: 'user', content: 'm$i'),
      ];
      final out = await c.compactAsync(msgs);
      // 保留 system + 最近 2 条
      expect(out.first.content, 'sys');
      expect(out, hasLength(3));
      expect(out.last.content, 'm5');
    });

    test('不超阈值返回同一引用', () async {
      const c = ContextCompactor(threshold: 100, keepRecent: 2);
      final msgs = [
        const ChatMessage(role: 'system', content: 'sys'),
        const ChatMessage(role: 'user', content: 'hi'),
      ];
      expect(await c.compactAsync(msgs), same(msgs));
    });

    test('注入 summarize：中间轮次摘要回填为一条 system 消息', () async {
      final c = ContextCompactor(
        threshold: 5,
        keepRecent: 2,
        summarize: (dropped) async {
          // 断言被丢弃的是中间消息（非 system、非最近 2 条）
          expect(dropped.map((m) => m.content), containsAll(['m1', 'm2', 'm3']));
          return const ChatMessage(role: 'system', content: '【摘要】已保存知识点 id=42');
        },
      );
      final msgs = [
        const ChatMessage(role: 'system', content: 'sys'),
        const ChatMessage(role: 'user', content: 'm0'),
        const ChatMessage(role: 'user', content: 'm1'),
        const ChatMessage(role: 'user', content: 'm2'),
        const ChatMessage(role: 'user', content: 'm3'),
        const ChatMessage(role: 'user', content: 'm4'),
        const ChatMessage(role: 'user', content: 'm5'),
      ];
      final out = await c.compactAsync(msgs);
      // system + 摘要 + 最近 2 条
      expect(out, hasLength(4));
      expect(out[0].content, 'sys');
      expect(out[1].content, contains('已保存知识点 id=42'));
      expect(out[2].content, 'm4');
      expect(out[3].content, 'm5');
    });

    test('摘要抛错时 fallback 硬截断，不阻断', () async {
      final c = ContextCompactor(
        threshold: 5,
        keepRecent: 2,
        summarize: (_) async => throw Exception('LLM 挂了'),
      );
      final msgs = [
        const ChatMessage(role: 'system', content: 'sys'),
        for (var i = 0; i < 6; i++) ChatMessage(role: 'user', content: 'm$i'),
      ];
      final out = await c.compactAsync(msgs);
      expect(out.first.content, 'sys');
      expect(out, hasLength(3)); // 硬截断结果
      expect(out.last.content, 'm5');
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
