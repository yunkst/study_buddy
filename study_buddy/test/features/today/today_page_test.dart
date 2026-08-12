// 今日 Tab：Ask-AI 三入口 + 空库待复习断言测试。
//
// 目标（Task 4.2 Step 1）：
// 1. 渲染 Ask-AI 区——「拍照」「从相册选择」「直接聊」三按钮各一处。
// 2. 空库 → 显示「今日待复习 0 张」。
//
// 测试基础设施（范式同 home_page_test）：
// - sqflite_ffi in-memory 真建空 db（TodayPage 经 databaseProvider/planListProvider/dueNowCountProvider 读数据）。
// - mock `study_buddy/overlay` channel（冷启动截图消费走 ScreenshotProvider.takePendingScreenshot），不依赖真实 Android。
// - AppTheme.light 提供 PaperColors 扩展（_SectionLabel/_NavRow 依赖 theme.extension<PaperColors>()?.ruleSoft）。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:study_buddy/core/providers/database_provider.dart';
import 'package:study_buddy/core/theme/app_theme.dart';
import 'package:study_buddy/features/today/today_page.dart';
import 'package:study_engine/study_engine.dart';

/// 查找类型为 T（含子类）且子树含文本 [label] 的按钮。
///
/// 必要性：`FilledButton.tonalIcon` 返回的是私有子类 `_FilledButtonWithTonalIcon`
/// （runtimeType 不等于公开类），`find.widgetWithText(T, label)` 内部
/// `find.byType` 无法匹配。用 `find.bySubtype<T>()`（按 `is T` 匹配子类）
/// 配合 descendant 文本。
Finder _buttonWithText<T extends Widget>(String label) =>
    find.descendant(
      of: find.bySubtype<T>(),
      matching: find.text(label),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  late StudyDatabase sdb;

  setUp(() async {
    sdb = await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
  });
  tearDown(() async => await sdb.close());

  const overlayChannel = MethodChannel('study_buddy/overlay');

  /// 装配今日页：mock overlay channel + in-memory db + AppTheme。
  Future<void> pumpTodayPage(WidgetTester tester, ProviderContainer container) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(overlayChannel, (MethodCall call) async {
      switch (call.method) {
        case 'checkOverlayPermission':
        case 'showOverlay':
        case 'hideOverlay':
        case 'takePendingScreenshot':
        default:
          return null;
      }
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(overlayChannel, null));

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.light,
        home: const TodayPage(),
      ),
    ));
    // sqflite_ffi 的查询是真实异步(基于 isolate),在 testWidgets 的 fake-async zone 中
    // 不会自动完成:先 pumpWidget 让 FutureProvider 的 future 在 fake zone 启动,
    // 再在 runAsync 的 real zone 等待 DB 查询完成,最后回 fake zone pumpAndSettle
    // 让 widget 重建为 data 态(loading 消失、文本可见)。
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
  }

  testWidgets('渲染 Ask-AI 三入口:拍照/从相册选择/直接聊', (tester) async {
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWith((ref) async => sdb),
    ]);
    addTearDown(container.dispose);

    await pumpTodayPage(tester, container);

    expect(_buttonWithText<FilledButton>('拍照'), findsOneWidget);
    expect(_buttonWithText<FilledButton>('从相册选择'), findsOneWidget);
    expect(_buttonWithText<FilledButton>('直接聊'), findsOneWidget);
  });

  testWidgets('空库:「今日待复习 0 张」', (tester) async {
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWith((ref) async => sdb),
    ]);
    addTearDown(container.dispose);

    await pumpTodayPage(tester, container);

    expect(find.text('今日待复习 0 张'), findsOneWidget);
  });
}