// ShareCardWidget：纯 widget 渲染测试。
//
// 验证（无需 db / 无平台依赖，纯 WidgetTester）：
// 1. 正常数据渲染无溢出（360×480 固定尺寸）。
// 2. 关键数据字段（连续打卡/今日专注/知识点/待复习/累计小时）正确显示。
// 3. AI 总结显示 / loading 占位。
// 4. 边界：今日没学时（0 专注/0 知识点）不溢出。
//
// 卡片硬编码亮色纸感色值、不依赖 Theme，因此无需 AppTheme/ProviderContainer。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:study_buddy/core/providers/share_card_provider.dart';
import 'package:study_buddy/features/share/share_card_widget.dart';
import 'package:study_engine/study_engine.dart';

ShareCardData _data({
  int streak = 28,
  int focusMinutes = 45,
  int topicCount = 6,
  int dueNow = 12,
  int totalFocusMinutes = 37 * 60,
}) {
  final now = DateTime(2026, 8, 13, 12);
  return ShareCardData(
    streak: streak,
    focusMinutes: focusMinutes,
    topics: List.generate(topicCount, (i) {
      return Topic(
        categoryId: 1,
        question: 'q$i',
        title: '知识点$i',
        summary: 's',
        createdAt: now,
        updatedAt: now,
      );
    }),
    dueNow: dueNow,
    totalFocusMinutes: totalFocusMinutes,
  );
}

void main() {
  final date = DateTime(2026, 8, 13);

  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: Center(child: child)));

  testWidgets('正常数据渲染，无溢出，关键字段正确', (tester) async {
    await tester.pumpWidget(wrap(
      ShareCardWidget(data: _data(), date: date),
    ));
    expect(tester.takeException(), isNull);
    expect(find.text('✏ 今日学习'), findsOneWidget);
    expect(find.text('2026 年 8 月 13 日 · 星期四'), findsOneWidget);
    expect(find.text('45 分钟'), findsOneWidget);
    expect(find.text('6 个知识点'), findsOneWidget);
    expect(find.text('12 道待复习'), findsOneWidget);
    expect(find.text('28 天'), findsOneWidget);
    expect(find.text('37 小时'), findsOneWidget);
    expect(find.text('#学习打卡 #StudyBuddy'), findsOneWidget);
  });

  testWidgets('AI 总结渲染到卡片', (tester) async {
    await tester.pumpWidget(wrap(
      ShareCardWidget(
        data: _data(),
        summary: '今天啃下了 极限、导数，又进步一点点！',
        date: date,
      ),
    ));
    expect(tester.takeException(), isNull);
    expect(find.text('今天啃下了 极限、导数，又进步一点点！'), findsOneWidget);
  });

  testWidgets('AI 总结 loading 显示占位', (tester) async {
    await tester.pumpWidget(wrap(
      ShareCardWidget(data: _data(), summaryLoading: true, date: date),
    ));
    expect(tester.takeException(), isNull);
    expect(find.text('正在写今日小结…'), findsOneWidget);
  });

  testWidgets('边界：今日没学（0 专注/0 知识点/0 待复习）不溢出', (tester) async {
    await tester.pumpWidget(wrap(
      ShareCardWidget(
        data: _data(streak: 0, focusMinutes: 0, topicCount: 0, dueNow: 0, totalFocusMinutes: 0),
        date: date,
      ),
    ));
    expect(tester.takeException(), isNull);
    expect(find.text('0 分钟'), findsOneWidget);
    expect(find.text('0 个知识点'), findsOneWidget);
    expect(find.text('0 天'), findsOneWidget);
    expect(find.text('0 小时'), findsOneWidget);
  });
}