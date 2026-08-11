// 首页「拍题问 AI」文章块 + 入口测试。
//
// 目标：
// 1. 已授权悬浮窗：首页可见「拍题问 AI」文章块（_ArticleLabel + FilledButton 文案）。
// 2. 未授权悬浮窗：同样可见——证明文章块与 _overlayGranted 解耦。
// 3. 点主按钮：底部 Sheet 弹出，「拍照」「从相册选择」两 ListTile 可见。
//
// 测试基础设施（范式同 daily_report_page_test）：
// - sqflite_ffi in-memory 真建空 db（HomePage 经 databaseProvider/planListProvider 读数据）。
// - mock `study_buddy/overlay` channel（悬浮窗权限检查/显隐），不依赖真实 Android。
// - AppTheme.light 提供 PaperColors 扩展（_Article 依赖 theme.extension<PaperColors>()!）。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:study_buddy/core/providers/database_provider.dart';
import 'package:study_buddy/core/theme/app_theme.dart';
import 'package:study_buddy/features/home/home_page.dart';
import 'package:study_engine/study_engine.dart';

/// 查找类型为 T（含子类）且子树含文本 [label] 的按钮。
///
/// 必要性：`FilledButton.icon` / `TextButton.icon` 返回的是私有子类
/// `_FilledButtonWithIcon` / `_TextButtonWithIcon`（runtimeType 不等于
/// 公开类），`find.widgetWithText(T, label)` 内部 `find.byType` 无法匹配。
/// 用 `find.bySubtype<T>()`（按 `is T` 匹配子类）配合 descendant 文本。
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

  /// 装配首页：mock overlay channel + in-memory db + AppTheme + GoRouter。
  Future<void> pumpHomePage(
    WidgetTester tester,
    ProviderContainer container, {
    required bool overlayGranted,
  }) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(overlayChannel, (MethodCall call) async {
      switch (call.method) {
        case 'checkOverlayPermission':
          return overlayGranted;
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
      child: MaterialApp.router(
        theme: AppTheme.light,
        routerConfig: GoRouter(routes: [
          GoRoute(path: '/', builder: (_, __) => const HomePage()),
        ]),
      ),
    ));
    // sqflite_ffi 的查询是真实异步(基于 isolate),在 testWidgets 的 fake-async zone 中
    // 不会自动完成:先 pumpWidget 让 FutureProvider 的 future 在 fake zone 启动,
    // 再在 runAsync 的 real zone 等待 DB 查询完成,最后回 fake zone pumpAndSettle
    // 让 widget 重建为 data 态(loading 消失、文章块可见)。
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
  }

  testWidgets('已授权悬浮窗:首页可见「拍题问 AI」文章块', (tester) async {
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWith((ref) async => sdb),
    ]);
    addTearDown(container.dispose);

    await pumpHomePage(tester, container, overlayGranted: true);

    // _ArticleLabel 文字 + 主按钮文案各一处「拍题问 AI」。
    expect(find.text('拍题问 AI'), findsWidgets);
    expect(_buttonWithText<FilledButton>('拍题问 AI'), findsOneWidget);
    expect(_buttonWithText<TextButton>('从相册选择题目'), findsOneWidget);
  });

  testWidgets('未授权悬浮窗:同样可见「拍题问 AI」文章块(与 _overlayGranted 解耦)', (tester) async {
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWith((ref) async => sdb),
    ]);
    addTearDown(container.dispose);

    await pumpHomePage(tester, container, overlayGranted: false);

    expect(find.text('拍题问 AI'), findsWidgets);
    expect(_buttonWithText<FilledButton>('拍题问 AI'), findsOneWidget);
    expect(_buttonWithText<TextButton>('从相册选择题目'), findsOneWidget);
  });

  testWidgets('点主按钮:底部 Sheet 弹出「拍照」「从相册选择」', (tester) async {
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWith((ref) async => sdb),
    ]);
    addTearDown(container.dispose);

    await pumpHomePage(tester, container, overlayGranted: true);

    // 文章块可能在首屏折叠下方:先滚动到可见再点。
    await tester.ensureVisible(_buttonWithText<FilledButton>('拍题问 AI'));
    await tester.tap(_buttonWithText<FilledButton>('拍题问 AI'));
    await tester.pumpAndSettle();

    expect(find.text('拍照'), findsOneWidget);
    expect(find.text('从相册选择'), findsOneWidget);
  });
}
