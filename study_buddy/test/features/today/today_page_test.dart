// 今日 Tab：单「问 AI」入口 + 空库待复习断言测试。
//
// 目标：
// 1. 渲染「问 AI」单个导航行入口（合并自原拍照/相册/直接聊三按钮）。
// 2. 空库 → 显示「今日待复习 0 张」。
// 3. tap「问 AI」→ 跳全屏对话页 /ai。
//
// 测试基础设施（范式同 home_page_test）：
// - sqflite_ffi in-memory 真建空 db（TodayPage 经 databaseProvider/planListProvider/dueNowCountProvider 读数据）。
// - GoRouter 装配 /today + /ai（tap「问 AI」会 context.push('/ai')）。
// - AppTheme.light 提供 PaperColors 扩展（_SectionLabel/_NavRow 依赖 theme.extension<PaperColors>()?.ruleSoft）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:study_buddy/core/providers/agent_session_provider.dart';
import 'package:study_buddy/core/providers/database_provider.dart';
import 'package:study_buddy/core/theme/app_theme.dart';
import 'package:study_buddy/features/external_qbank/ai_panel_sheet.dart';
import 'package:study_buddy/features/today/today_page.dart';
import 'package:study_engine/study_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  setUp(() => SharedPreferences.setMockInitialValues({})); // dueNowCountProvider 依赖 dailyReviewLimitProvider

  late StudyDatabase sdb;

  setUp(() async {
    sdb = await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
  });
  tearDown(() async => await sdb.close());

  /// 装配今日页：in-memory db + AppTheme + GoRouter（含 /today /ai）。
  Future<void> pumpTodayPage(WidgetTester tester, ProviderContainer container,
      {List<RouteBase> extraRoutes = const []}) async {
    final router = GoRouter(
      initialLocation: '/today',
      routes: [
        GoRoute(path: '/today', builder: (_, __) => const TodayPage()),
        GoRoute(
          path: '/ai',
          builder: (_, state) => const AiChatPage(),
        ),
        ...extraRoutes,
      ],
    );
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        theme: AppTheme.light,
      ),
    ));
    // sqflite_ffi 的查询是真实异步(基于 isolate),在 testWidgets 的 fake-async zone 中
    // 不会自动完成:先 pumpWidget 让 FutureProvider 的 future 在 fake zone 启动,
    // 再在 runAsync 的 real zone 等待 DB 查询完成,最后回 fake zone pumpAndSettle
    // 让 widget 重建为 data 态(loading 消失、文本可见)。
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
  }

  testWidgets('渲染单个「问 AI」入口（合并自三按钮）', (tester) async {
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWith((ref) async => sdb),
    ]);
    addTearDown(container.dispose);

    await pumpTodayPage(tester, container);

    expect(find.text('问 AI'), findsOneWidget);
    // 旧三按钮不再存在
    expect(find.text('拍照'), findsNothing);
    expect(find.text('从相册选择'), findsNothing);
    expect(find.text('直接聊'), findsNothing);
  });

  testWidgets('空库:「今日待复习 0 张」', (tester) async {
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWith((ref) async => sdb),
    ]);
    addTearDown(container.dispose);

    await pumpTodayPage(tester, container);

    expect(find.text('今日待复习 0 张'), findsOneWidget);
  });

  testWidgets('tap「问 AI」→ 进入全屏对话页', (tester) async {
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWith((ref) async => sdb),
      agentSessionProvider.overrideWith((ref) => _NoopAgentSession(ref)),
    ]);
    addTearDown(container.dispose);

    await pumpTodayPage(tester, container);

    await tester.tap(find.text('问 AI'));
    await tester.pumpAndSettle();

    // 进入全屏对话页：AppBar 标题「问 AI」可见
    expect(find.byType(AiChatPage), findsOneWidget);
    // 空态引导的副标题可见
    expect(find.text('拍照问一道题，或直接输入你的疑问'), findsOneWidget);
  });
}

/// Noop AgentSession：今日页测试不需要真实 run，仅占位避免默认 provider 报错。
class _NoopAgentSession extends AgentSession {
  _NoopAgentSession(super.ref);
  @override
  Future<AgentSessionHandle> run(List<ChatMessage> messages, {int? chatSessionId, int? planId, DateTime? today}) async {
    return AgentSessionHandle(stream: const Stream.empty());
  }
}
