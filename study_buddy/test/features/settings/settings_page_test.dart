import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
    // 预览通道开关等 SharedPreferences 偏好，默认关闭。
    SharedPreferences.setMockInitialValues({});
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

  testWidgets('设置页渲染外观/系统两个分组(默认态)', (tester) async {
    await pumpSettings(tester);
    // 外观是首屏第一分组，直接可见。
    expect(find.text('外观'), findsOneWidget);
    expect(find.text('主题模式'), findsOneWidget);
    // 系统在下方，滚动到可见后断言（懒构建）。
    await tester.scrollUntilVisible(
      find.text('系统'),
      200,
      scrollable: find.byType(Scrollable),
    );
    await tester.pumpAndSettle();
    expect(find.text('系统'), findsOneWidget);
    // 诊断分组仅在开发者模式开启时渲染，默认态不出现（由 devMode 开启用例覆盖）。
    expect(find.text('诊断'), findsNothing);
  });

  testWidgets('设置页渲染系统分组三个入口(LLM配置/版本更新/关于)', (tester) async {
    await pumpSettings(tester);
    // master 加了每日复盘限额行，系统分组更长；逐个滚动到可见再断言，
    // 避免单个 scrollUntilVisible 把上方的目标滚出视口。
    for (final t in ['LLM 配置', '版本更新', '关于']) {
      await tester.scrollUntilVisible(
        find.text(t),
        200,
        scrollable: find.byType(Scrollable),
      );
      await tester.pumpAndSettle();
      expect(find.text(t), findsOneWidget);
    }
  });

  testWidgets('开发者模式关闭时,诊断分组与日志入口不渲染', (tester) async {
    // 初始 devMode 关闭（setMockInitialValues 默认空），诊断分组整体隐藏。
    await pumpSettings(tester);
    expect(find.text('诊断'), findsNothing);
    expect(find.text('应用日志'), findsNothing);
    expect(find.text('LLM 调用日志'), findsNothing);
  });

  testWidgets('开启开发者模式后,诊断分组与两个日志入口出现', (tester) async {
    // 通过 SharedPreferences 注入初始值，使 devModeProvider 首帧即为 true。
    SharedPreferences.setMockInitialValues({'dev_mode_enabled': true});
    await pumpSettings(tester);
    await tester.scrollUntilVisible(
      find.text('LLM 调用日志'),
      200,
      scrollable: find.byType(Scrollable),
    );
    await tester.pumpAndSettle();
    expect(find.text('诊断'), findsOneWidget);
    expect(find.text('应用日志'), findsOneWidget);
    expect(find.text('LLM 调用日志'), findsOneWidget);
  });

  testWidgets('开发者模式关闭时,提示词设置与预览版下载不展示', (tester) async {
    await pumpSettings(tester);
    // 系统分组默认可见的行：LLM 配置、每日复习上限、版本更新、关于。
    // 提示词设置、预览版下载受 dev mode 控制，默认不展示。
    expect(find.text('提示词设置'), findsNothing);
    expect(find.text('预览版下载'), findsNothing);
  });

  testWidgets('开启开发者模式后,提示词设置与预览版下载出现', (tester) async {
    SharedPreferences.setMockInitialValues({'dev_mode_enabled': true});
    await pumpSettings(tester);
    await tester.scrollUntilVisible(
      find.text('预览版下载'),
      200,
      scrollable: find.byType(Scrollable),
    );
    await tester.pumpAndSettle();
    expect(find.text('提示词设置'), findsOneWidget);
    expect(find.text('预览版下载'), findsOneWidget);
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

  /// 以 devMode 开启的初始值 pump 设置页（预览版下载等受控行依赖开发者模式）。
  /// 传入额外偏好（如 app_update_preview_channel）时合并进去。
  Future<void> pumpSettingsWithDevMode(
    WidgetTester tester, {
    Map<String, Object> extraPrefs = const {},
  }) async {
    SharedPreferences.setMockInitialValues({
      'dev_mode_enabled': true,
      ...extraPrefs,
    });
    await pumpSettings(tester);
  }

  /// 滚动系统分组到「预览版下载」开关可见（ListView 懒构建）。
  /// 前置条件：开发者模式已开启（预览版下载行受其控制）。
  Future<void> scrollToPreviewSwitch(WidgetTester tester) async {
    await tester.scrollUntilVisible(
      find.text('预览版下载'),
      200,
      scrollable: find.byType(Scrollable),
    );
    await tester.pumpAndSettle();
  }

  /// 指定设置行（按 label 文案定位）内的 Switch。
  /// 设置页出现多个开关（预览版下载/开发者模式）后，find.byType(Switch) 会命中多个，
  /// 必须按行限定。
  Finder previewOrDevSwitch(String label) => find.descendant(
        of: find.widgetWithText(Container, label),
        matching: find.byType(Switch),
      );

  testWidgets('设置页渲染预览版下载开关行', (tester) async {
    await pumpSettingsWithDevMode(tester);
    await scrollToPreviewSwitch(tester);
    expect(find.text('预览版下载'), findsOneWidget);
    // 初始关闭。
    expect(tester.widget<Switch>(previewOrDevSwitch('预览版下载')).value, isFalse);
  });

  testWidgets('打开预览版开关先弹非常不稳定提醒,确认后开启', (tester) async {
    await pumpSettingsWithDevMode(tester);
    await scrollToPreviewSwitch(tester);

    await tester.tap(previewOrDevSwitch('预览版下载'));
    await tester.pumpAndSettle();
    // 提醒对话框：标题 + 非常不稳定文案 + 两个按钮。
    expect(find.text('开启预览版下载'), findsOneWidget);
    expect(find.textContaining('非常不稳定'), findsOneWidget);
    expect(find.text('继续开启'), findsOneWidget);
    expect(find.text('再想想'), findsOneWidget);

    await tester.tap(find.text('继续开启'));
    await tester.pumpAndSettle();
    // 确认后开关开启。
    expect(tester.widget<Switch>(previewOrDevSwitch('预览版下载')).value, isTrue);
  });

  testWidgets('打开预览版开关取消则保持关闭', (tester) async {
    await pumpSettingsWithDevMode(tester);
    await scrollToPreviewSwitch(tester);

    await tester.tap(previewOrDevSwitch('预览版下载'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('再想想'));
    await tester.pumpAndSettle();
    // 取消：对话框关闭，开关保持关闭。
    expect(find.text('开启预览版下载'), findsNothing);
    expect(tester.widget<Switch>(previewOrDevSwitch('预览版下载')).value, isFalse);
  });

  testWidgets('已开启预览版时点开关直接关闭,无提醒', (tester) async {
    await pumpSettingsWithDevMode(
      tester,
      extraPrefs: {'app_update_preview_channel': true},
    );
    await scrollToPreviewSwitch(tester);
    expect(tester.widget<Switch>(previewOrDevSwitch('预览版下载')).value, isTrue);

    await tester.tap(previewOrDevSwitch('预览版下载'));
    await tester.pumpAndSettle();
    // 关闭无需确认，无提醒对话框，开关直接关闭。
    expect(find.text('开启预览版下载'), findsNothing);
    expect(tester.widget<Switch>(previewOrDevSwitch('预览版下载')).value, isFalse);
  });

  /// 滚动到「开发者模式」开关可见（开发者分组在诊断分组之下，需继续下滚）。
  Future<void> scrollToDevSwitch(WidgetTester tester) async {
    await tester.scrollUntilVisible(
      find.text('开发者模式'),
      200,
      scrollable: find.byType(Scrollable),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('设置页渲染开发者模式开关行（初始关闭）', (tester) async {
    await pumpSettings(tester);
    await scrollToDevSwitch(tester);
    expect(find.text('开发者模式'), findsOneWidget);
    // 初始关闭。
    expect(tester.widget<Switch>(previewOrDevSwitch('开发者模式')).value, isFalse);
  });

  testWidgets('开启开发者模式开关立即生效（无确认弹窗）', (tester) async {
    await pumpSettings(tester);
    await scrollToDevSwitch(tester);

    await tester.tap(previewOrDevSwitch('开发者模式'));
    await tester.pumpAndSettle();
    // 开发者模式不同于预览版下载，不需要确认弹窗。
    expect(find.text('开启预览版下载'), findsNothing);
    // 开启后列表插入诊断分组，「开发者」行被推离视口并懒回收，
    // 需重新滚动到可见再读 Switch 值。
    await scrollToDevSwitch(tester);
    expect(tester.widget<Switch>(previewOrDevSwitch('开发者模式')).value, isTrue);
  });
}