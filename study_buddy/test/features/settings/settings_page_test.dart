import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:study_buddy/core/providers/database_provider.dart';
import 'package:study_buddy/core/theme/app_theme.dart';
import 'package:study_buddy/features/settings/settings_page.dart';
import 'package:study_engine/study_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  late StudyDatabase sdb;

  setUp(() async {
    sdb = await StudyDatabase.open(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
  });
  tearDown(() async => await sdb.close());

  /// sqflite_ffi 的查询是真实异步(基于 isolate),在 testWidgets 的
  /// fake-async zone 中不会自动完成。先 pumpWidget 让 provider 的 future
  /// 在 fake zone 启动,再在 runAsync 的 real zone 等待 db/provider 完成,
  /// 最后回 fake zone pumpAndSettle 让 widget 重建为数据态。
  /// (沿用 daily_report_page_test 的既定模式)
  Future<void> pumpSettings(WidgetTester tester) async {
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWith((ref) async => sdb),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.light,
        home: const SettingsPage(),
      ),
    ));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
  }

  testWidgets('SettingsPage 渲染诊断版块与两个入口', (tester) async {
    // PaperColors extension 由 AppTheme 注册,SettingsPage 依赖 ruleSoft 分隔线。
    // SettingsPage 现依赖 llmConfigProvider(进而依赖 databaseProvider),
    // 故测试需用 ProviderScope + inMemory database override,否则 build 抛缺失。
    await pumpSettings(tester);
    expect(find.text('诊断'), findsOneWidget);
    expect(find.text('应用日志'), findsOneWidget);
    expect(find.text('LLM 调用日志'), findsOneWidget);
  });

  testWidgets('LLM 配置板块渲染四字段与保存按钮', (tester) async {
    await pumpSettings(tester);
    expect(find.text('LLM 配置'), findsOneWidget);
    expect(find.text('名称'), findsWidgets);
    expect(find.text('API 地址'), findsWidgets);
    expect(find.text('API Key'), findsWidgets);
    expect(find.text('模型'), findsWidgets);
    expect(find.text('保存'), findsOneWidget);
  });
}
