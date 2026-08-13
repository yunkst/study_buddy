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

  testWidgets('设置页渲染外观/系统/诊断三个分组', (tester) async {
    await pumpSettings(tester);
    // 外观是首屏第一分组，直接可见。
    expect(find.text('外观'), findsOneWidget);
    expect(find.text('主题模式'), findsOneWidget);
    // 系统/诊断在 ListView 下方（懒构建），上滚后可看到。
    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(find.text('系统'), findsOneWidget);
    expect(find.text('诊断'), findsOneWidget);
  });

  testWidgets('设置页渲染系统分组三个入口(LLM配置/版本更新/关于)', (tester) async {
    await pumpSettings(tester);
    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(find.text('LLM 配置'), findsOneWidget);
    expect(find.text('版本更新'), findsOneWidget);
    expect(find.text('关于'), findsOneWidget);
  });

  testWidgets('设置页渲染诊断分组两个入口', (tester) async {
    await pumpSettings(tester);
    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(find.text('应用日志'), findsOneWidget);
    expect(find.text('LLM 调用日志'), findsOneWidget);
  });

  testWidgets('点击 LLM 配置弹出底部表单四字段与保存按钮', (tester) async {
    await pumpSettings(tester);
    // LLM 配置入口行：未配置时不铺表单，首屏无四字段。
    expect(find.text('名称'), findsNothing);
    expect(find.text('保存'), findsNothing);
    await tester.tap(find.text('LLM 配置'));
    await tester.pumpAndSettle();
    // 底部表单弹出：四字段 + 保存 + 标题。
    expect(find.text('名称'), findsWidgets);
    expect(find.text('API 地址'), findsWidgets);
    expect(find.text('API Key'), findsWidgets);
    expect(find.text('模型'), findsWidgets);
    expect(find.text('保存'), findsOneWidget);
  });
}