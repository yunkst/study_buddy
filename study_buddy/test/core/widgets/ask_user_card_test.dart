import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:study_buddy/core/theme/app_theme.dart';
import 'package:study_buddy/core/widgets/ask_user_card.dart';
import 'package:study_engine/study_engine.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: AppTheme.light,
    home: Scaffold(body: child),
  );
}

const _singleReq = AskUserRequest(
  question: '选哪个学科？',
  header: '学科',
  toolCallId: 'ask-1',
  options: [
    AskUserOption(label: '数学', value: 'math', description: '理工科'),
    AskUserOption(label: '英语', value: 'eng'),
  ],
);

void main() {
  testWidgets('单选：点选项立即 onSubmit(value)', (tester) async {
    String? submitted;
    await tester.pumpWidget(_wrap(
      AskUserCard(request: _singleReq, onSubmit: (v) => submitted = v),
    ));

    expect(find.text('选哪个学科？'), findsOneWidget);
    expect(find.text('数学'), findsOneWidget);
    expect(find.text('英语'), findsOneWidget);

    await tester.tap(find.text('数学'));
    await tester.pump();
    expect(submitted, 'math');
  });

  testWidgets('多选：勾选累积，提交按钮输出 "v1, v2"', (tester) async {
    String? submitted;
    const req = AskUserRequest(
      question: '薄弱科目？',
      toolCallId: 'ask-2',
      multiSelect: true,
      options: [
        AskUserOption(label: '高数', value: 'calc'),
        AskUserOption(label: '线代', value: 'linalg'),
        AskUserOption(label: '概率', value: 'prob'),
      ],
    );
    await tester.pumpWidget(_wrap(
      AskUserCard(request: req, onSubmit: (v) => submitted = v),
    ));

    // 未勾选时提交按钮禁用
    final submitBtn = find.widgetWithText(FilledButton, '提交（0项）');
    expect(submitBtn, findsOneWidget);

    // 勾选两个
    await tester.tap(find.text('高数'));
    await tester.pump();
    await tester.tap(find.text('线代'));
    await tester.pump();

    expect(find.widgetWithText(FilledButton, '提交（2项）'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '提交（2项）'));
    await tester.pump();
    expect(submitted, 'calc, linalg');
  });

  testWidgets('自由输入：空文本不提交，非空提交', (tester) async {
    String? submitted;
    const req = AskUserRequest(
      question: '你的目标分是多少？',
      toolCallId: 'ask-3',
      options: [],
    );
    await tester.pumpWidget(_wrap(
      AskUserCard(request: req, onSubmit: (v) => submitted = v),
    ));

    // 空文本提交无效
    await tester.tap(find.widgetWithText(FilledButton, '提交答案'));
    await tester.pump();
    expect(submitted, isNull);

    // 输入后提交
    await tester.enterText(find.byType(TextField), '目标 380 分');
    await tester.tap(find.widgetWithText(FilledButton, '提交答案'));
    await tester.pump();
    expect(submitted, '目标 380 分');
  });
}
