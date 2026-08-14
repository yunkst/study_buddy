import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:study_buddy/core/widgets/typewriter_text.dart';

/// 打字机渲染 harness:builder 直接渲染部分文本,便于断言揭示进度。
Widget _harness({
  required String text,
  bool active = true,
  Duration tick = const Duration(milliseconds: 40),
}) {
  return MaterialApp(
    home: Scaffold(
      body: TypewriterText(
        text: text,
        active: active,
        tick: tick,
        builder: (_, partial) => Text(partial),
      ),
    ),
  );
}

/// 当前屏幕上的部分文本。
String _partial(WidgetTester tester) =>
    tester.widget<Text>(find.byType(Text)).data ?? '';

void main() {
  group('typewriterStepForSlack(积压→每拍揭示数)映射', () {
    test('积压<=0:缓存耗尽,暂停(0 字/拍)', () {
      expect(typewriterStepForSlack(0), 0);
      expect(typewriterStepForSlack(-3), 0);
    });

    test('低积压(1~16):逐字(1 字/拍)', () {
      expect(typewriterStepForSlack(1), 1);
      expect(typewriterStepForSlack(8), 1);
      expect(typewriterStepForSlack(16), 1);
    });

    test('中积压线性爬升(17~80 → 2~5 字/拍)', () {
      expect(typewriterStepForSlack(17), 2);
      expect(typewriterStepForSlack(32), 2);
      expect(typewriterStepForSlack(33), 3);
      expect(typewriterStepForSlack(48), 3);
      expect(typewriterStepForSlack(49), 4);
      expect(typewriterStepForSlack(64), 4);
      expect(typewriterStepForSlack(65), 5);
      expect(typewriterStepForSlack(80), 5);
    });

    test('高积压(>=81):提速到上限(6 字/拍)', () {
      expect(typewriterStepForSlack(81), 6);
      expect(typewriterStepForSlack(500), 6);
    });
  });

  group('TypewriterText widget', () {
    testWidgets('低积压逐字推进,揭示完成后停在全文', (tester) async {
      await tester.pumpWidget(_harness(text: '0123456789'));

      // 首帧:尚未揭示
      expect(_partial(tester), '');
      // 每拍 1 字(积压始终 <=16)
      await tester.pump(const Duration(milliseconds: 40));
      expect(_partial(tester), '0');
      await tester.pump(const Duration(milliseconds: 40));
      expect(_partial(tester), '01');
      // 多拍后揭示完成,继续保持全文(不再漂移)
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 40));
      }
      expect(_partial(tester), '0123456789');
    });

    testWidgets('高积压提速:每拍揭示 6 字快速追上缓存', (tester) async {
      final text = 'x' * 100;
      await tester.pumpWidget(_harness(text: text));

      await tester.pump(const Duration(milliseconds: 40));
      expect(_partial(tester).length, 6);
      await tester.pump(const Duration(milliseconds: 40));
      expect(_partial(tester).length, 12);
    });

    testWidgets('active=false:立即显示全文,不走打字机', (tester) async {
      await tester.pumpWidget(
        _harness(text: '标定与内插', active: false),
      );
      expect(_partial(tester), '标定与内插');
      // 多拍后仍是全文(没有定时器在推进)
      await tester.pump(const Duration(milliseconds: 200));
      expect(_partial(tester), '标定与内插');
    });

    testWidgets('目标文本增长(流式增量)时,从已揭示位置继续', (tester) async {
      await tester.pumpWidget(_harness(text: 'abc'));
      await tester.pump(const Duration(milliseconds: 40)); // → a
      await tester.pump(const Duration(milliseconds: 40)); // → ab

      // 流式追加:同一 element 复用 state,不从头重打
      await tester.pumpWidget(_harness(text: 'abcdef'));
      expect(_partial(tester), 'ab');
      await tester.pump(const Duration(milliseconds: 40));
      expect(_partial(tester), 'abc');
    });

    testWidgets('目标缩短(重试/轮次切换)时重置为从新文本开头打', (tester) async {
      await tester.pumpWidget(_harness(text: 'abcdefghij'));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 40)); // 揭示 5 字
      }
      expect(_partial(tester), 'abcde');

      // 模拟 LLM 重试:全文换成一个更短的新回答 → 应重置为 0 重新打字
      await tester.pumpWidget(_harness(text: '新回复'));
      expect(_partial(tester), '');
      await tester.pump(const Duration(milliseconds: 40));
      expect(_partial(tester), '新');
      await tester.pump(const Duration(milliseconds: 40));
      expect(_partial(tester), '新回');
    });

    testWidgets('揭示完成后清空,新流到来重新打字', (tester) async {
      await tester.pumpWidget(_harness(text: '回答一'));
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 40));
      }
      expect(_partial(tester), '回答一');

      // 轮次结束:streamingText 清空
      await tester.pumpWidget(_harness(text: ''));
      expect(_partial(tester), '');

      // 下一轮新流从头打
      await tester.pumpWidget(_harness(text: '回答二'));
      expect(_partial(tester), '');
      await tester.pump(const Duration(milliseconds: 40));
      expect(_partial(tester), '回');
    });
  });
}