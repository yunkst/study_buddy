import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:study_buddy/core/services/logger_service.dart';
import 'package:study_buddy/core/theme/app_theme.dart';
import 'package:study_buddy/features/logs/app_log_viewer_page.dart';

void main() {
  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    // LoggerService 持久化走 SharedPreferences,测试环境需注入 mock。
    SharedPreferences.setMockInitialValues({});
    LoggerService.resetForTesting();
  });

  // LoggerService 写入会调度 1s persist Timer,需排空避免 pending timer 断言。
  Future<void> drainTimers(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 2));
    await LoggerService.instance.flush();
  }

  testWidgets('渲染统计条与日志列表', (tester) async {
    LoggerService.instance.i('hello', category: LogCategory.ai);
    LoggerService.instance.e('boom', category: LogCategory.database);
    await tester.pumpWidget(
      MaterialApp(theme: AppTheme.light, home: const AppLogViewerPage()),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('共'), findsOneWidget); // 统计条
    expect(find.text('hello'), findsOneWidget);
    expect(find.text('boom'), findsOneWidget);
    await drainTimers(tester);
  });

  testWidgets('点击日志项展开详情', (tester) async {
    LoggerService.instance.i('详细内容在这');
    await tester.pumpWidget(
      MaterialApp(theme: AppTheme.light, home: const AppLogViewerPage()),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('详细内容在这'));
    await tester.pumpAndSettle();
    expect(find.textContaining('详细内容'), findsWidgets);
    await drainTimers(tester);
  });

  testWidgets('级别过滤仅显示匹配项', (tester) async {
    LoggerService.instance.i('info-msg', category: LogCategory.ai);
    LoggerService.instance.e('error-msg', category: LogCategory.database);
    await tester.pumpWidget(
      MaterialApp(theme: AppTheme.light, home: const AppLogViewerPage()),
    );
    await tester.pumpAndSettle();
    expect(find.text('info-msg'), findsOneWidget);
    expect(find.text('error-msg'), findsOneWidget);
    // 点击 error 级别 FilterChip 过滤(chip 类型限定,避免与日志项级别标签歧义)
    final errorChip = find.ancestor(
      of: find.text('error'),
      matching: find.byType(FilterChip),
    );
    await tester.ensureVisible(errorChip);
    await tester.tap(errorChip);
    await tester.pumpAndSettle();
    expect(find.text('info-msg'), findsNothing);
    expect(find.text('error-msg'), findsOneWidget);
    await drainTimers(tester);
  });

  testWidgets('关键词搜索过滤', (tester) async {
    LoggerService.instance.i('Alpha content');
    LoggerService.instance.i('Beta content');
    await tester.pumpWidget(
      MaterialApp(theme: AppTheme.light, home: const AppLogViewerPage()),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'alpha');
    await tester.pumpAndSettle();
    expect(find.text('Alpha content'), findsOneWidget);
    expect(find.text('Beta content'), findsNothing);
    await drainTimers(tester);
  });

  testWidgets('清空日志走确认对话框', (tester) async {
    LoggerService.instance.i('keep-or-clear');
    await tester.pumpWidget(
      MaterialApp(theme: AppTheme.light, home: const AppLogViewerPage()),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('清空'));
    await tester.pumpAndSettle();
    expect(find.text('清空日志'), findsOneWidget);
    // clearLogs 内 await _persistLogs()(走真实 SharedPreferences 微任务链),
    // 用 runAsync 让其整条异步链(_clear → showDialog pop → clearLogs → persist → notifier++)完成。
    await tester.runAsync<void>(() async {
      await tester.tap(find.widgetWithText(TextButton, '清空'));
      // _clear 的 await showDialog → Navigator.pop 返回 → await clearLogs() 整条链。
      await tester.pumpAndSettle();
    });
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text('keep-or-clear'), findsNothing);
    expect(LoggerService.instance.logCount, 0);
    await drainTimers(tester);
  });
}
