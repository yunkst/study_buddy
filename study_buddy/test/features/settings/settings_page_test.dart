import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:study_buddy/core/theme/app_theme.dart';
import 'package:study_buddy/features/settings/settings_page.dart';

void main() {
  testWidgets('SettingsPage 渲染诊断版块与两个入口', (tester) async {
    // PaperColors extension 由 AppTheme 注册,SettingsPage 依赖 ruleSoft 分隔线。
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: const SettingsPage(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('诊断'), findsOneWidget);
    expect(find.text('应用日志'), findsOneWidget);
    expect(find.text('LLM 调用日志'), findsOneWidget);
  });
}

