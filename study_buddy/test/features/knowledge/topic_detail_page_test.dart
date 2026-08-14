// 知识点详情页 widget 测试。
//
// 目标（Task 5.5）：
// 1. seed 分类「数学」+ topic「夹逼定理」（question 含 `$f\le g\le h$` 公式，
//    summary 含 Markdown）+ topic_schedule 行 stability=25（≥kMasteredStabilityThreshold
//    → mastered）。
// 2. 渲染 TopicDetailPage 后断言：标题「夹逼定理」渲染 + 引子 MarkdownLatex 存在
//    + 掌握度徽标「已掌握」渲染。
//
// 基础设施与范式（沿用 knowledge_page_test / saved_topic_capsule_test）：
// - sqflite_ffi in-memory 真建 db；DB open 与 seed 放 setUp 的 real-async zone
//   （在 testWidgets fake-async zone 内 await insert 会永久挂起）。
// - seed 直接用 sdb.db.insert + Category/Topic/TopicSchedule.toMap，避开 repos。
// - masteryOfProvider 派生 MasteryStatus：topic_schedule stability=25 → mastered。
// - 用 MaterialApp.router + GoRouter 提供 /topic/:id（TopicDetailPage 的 context.push
//   / context.pop 需要 Router context；裸 MaterialApp 会崩）。
// - AppTheme.light 提供 PaperColors 扩展（_EdgeChip/_Timeline/_SectionLabel 兜底）。
// - pending Timer 处理：pumpAndSettle 后 pump 11s 消化 sqflite txnSynchronized
//   留下的 lock-warning Timer，避免 teardown 报「Timer still pending」。
// - 引子用 MarkdownLatex 渲染（$...$ → latex 元素 → Math.tex），无法用 find.text
//   直接命中公式原文；这里用 byWidgetPredicate + MarkdownLatex 类型断言引子存在。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:study_buddy/core/providers/agent_session_provider.dart';
import 'package:study_buddy/core/providers/database_provider.dart';
import 'package:study_buddy/core/theme/app_theme.dart';
import 'package:study_buddy/core/widgets/markdown_latex.dart';
import 'package:study_buddy/features/knowledge/topic_detail_page.dart';
import 'package:study_engine/study_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  late StudyDatabase sdb;
  late int seededTopicId;

  setUp(() async {
    sdb = await StudyDatabase.open(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    final now = DateTime.now();
    // seed 顶级分类「数学」。
    final mathCategoryId = await sdb.db.insert(
      'category',
      Category(parentId: null, name: '数学', createdAt: now).toMap(),
    );
    // seed 知识点「夹逼定理」：question 含 `$f\le g\le h$` 公式，
    // summary 含 Markdown（Heading + 一段含公式 + 一段 plain）。
    final topicId = await sdb.db.insert(
      'topic',
      Topic(
        categoryId: mathCategoryId,
        question: '夹逼定理的夹逼对象是什么？例如 \$f\\le g\\le h\$。',
        title: '夹逼定理',
        summary:
            '## 定义\n\n若 \$f\\le g\\le h\$ 且 \$\\lim f=\\lim h=L\$，则 \$\\lim g=L\$。',
        createdAt: now,
        updatedAt: now,
      ).toMap(),
    );
    seededTopicId = topicId;
    // seed topic_schedule：stability=25（≥kMasteredStabilityThreshold(21)）→ mastered。
    // 与 saved_topic_capsule_test 范式一致：直插 toMap + topic_schedule。
    await sdb.db.insert(
      'topic_schedule',
      TopicSchedule(
        topicId: topicId,
        stability: 25,
        difficulty: 5,
        reps: 2,
        lapses: 0,
        lastReviewedAt: now,
      ).toMap(),
    );
  });
  tearDown(() async => await sdb.close());

  /// 装配详情页：in-memory db + AppTheme.light + MaterialApp.router + GoRouter。
  ///
  /// 路由：`/topic/:id` 渲染 TopicDetailPage(topicId)；`/review` 是 TopicDetailPage
  /// 底部「背诵」按钮的跳转目标（不点不触发，但需注册以防路由 miss）。
  Future<void> pumpDetailPage(WidgetTester tester, ProviderContainer container) async {
    final router = GoRouter(
      initialLocation: '/topic/$seededTopicId',
      routes: [
        GoRoute(
          path: '/topic/:id',
          builder: (context, state) {
            final id = int.tryParse(state.pathParameters['id'] ?? '');
            return TopicDetailPage(topicId: id ?? 0);
          },
        ),
        GoRoute(
          path: '/review',
          builder: (_, __) => const Scaffold(body: SizedBox.shrink()),
        ),
        // 【为什么？】按钮的跳转目标（占位，避免构造真实 AiChatPage 依赖 LLM）。
        GoRoute(
          path: '/ai',
          builder: (_, __) => const Scaffold(body: Center(child: Text('ai-page'))),
        ),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          routerConfig: router,
          theme: AppTheme.light,
        ),
      ),
    );
    // sqflite_ffi 查询是真实异步（isolate），fake-async zone 不会自动推进：
    // 先 pumpWidget 启动 FutureProvider，runAsync real zone 等 DB 查询完成，
    // 再 pumpAndSettle 渲染 data 态。
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pumpAndSettle();
    // sqflite txnSynchronized 在 fake zone 留下一个 10s 的 lock-warning Timer；
    // pumpAndSettle 只推进到无帧调度，不会触碰 pending Timer，这里显式推进 fake
    // time 让该一次性 Timer 到期（onTimeout 仅打印告警，无害），避免 teardown
    // 「Timer still pending」断言失败。
    await tester.pump(const Duration(seconds: 11));
  }

  testWidgets('渲染标题「夹逼定理」+ 引子 MarkdownLatex +「已掌握」徽标', (tester) async {
    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWith((ref) async => sdb)],
    );
    addTearDown(container.dispose);

    await pumpDetailPage(tester, container);

    // 1) 标题「夹逼定理」渲染（Text 直接渲染，不经过 MarkdownLatex）。
    expect(find.text('夹逼定理'), findsOneWidget);

    // 2) 引子 MarkdownLatex 存在。
    // 引子内容为带 `$f\le g\le h$` 的字符串，MarkdownLatex 会把它解析为 latex 元素
    // 并以 Math.tex 渲染，所以 find.text 命中不到整段原文；但 MarkdownLatex 组件本身
    // 一定会出现一次。
    expect(find.byType(MarkdownLatex), findsWidgets);

    // 3) 掌握度徽标「已掌握」渲染。
    // _MasteryBadge 内部 switch(status=mastered) → '已掌握'。
    expect(find.text('已掌握'), findsOneWidget);
  });

  testWidgets('【为什么？】:点击后按钮变「正在思考」,AI 首个 token 到达才跳转 /ai', (tester) async {
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWith((ref) async => sdb),
      agentSessionProvider.overrideWith((ref) => _FakeAgentSession(ref)),
    ]);
    addTearDown(container.dispose);

    await pumpDetailPage(tester, container);

    expect(find.byKey(const ValueKey('why-button')), findsOneWidget);
    expect(find.text('为什么？'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('why-button')));
    await tester.pump();
    // 等待态：按钮变「正在思考怎么和你解释..」（未立即跳转）
    expect(find.text('正在思考怎么和你解释..'), findsOneWidget);
    expect(find.text('ai-page'), findsNothing);

    // startTeaching 的恢复查询是真实异步（sqflite isolate），runAsync 推进；
    // fake 事件流首个 TextDelta 到达 → resolve → push /ai。
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    expect(find.text('ai-page'), findsOneWidget);

    // startTeaching 触发的 createSession / flushPersist 写库（sqflite isolate
    // 真实异步）在断言通过后仍在后台飞行中；若直接 container.dispose（本测试开头
    // 注册，LIFO 后执行），未完成的 _flushPersist 访问已释放的 _ref 会抛
    // UnmountedRefException。addTearDown 回调运行在 real async zone（实测：真实
    // Future.delayed 会完成），故在此注册一个真实等待，让写链在 dispose 前跑完。
    // LIFO 顺序：本回调先于上面的 container.dispose 执行。
    addTearDown(() => Future<void>.delayed(const Duration(seconds: 2)));
  });
}

/// 假 AgentSession：事件流立即放完，记录收到的 topicId。
class _FakeAgentSession extends AgentSession {
  _FakeAgentSession(super.ref);
  final List<int?> receivedTopicIds = [];
  @override
  Future<AgentSessionHandle> run(List<ChatMessage> messages,
      {int? chatSessionId, int? planId, DateTime? today, int? topicId}) async {
    receivedTopicIds.add(topicId);
    return AgentSessionHandle(
      stream: Stream.fromIterable(
          [TextDeltaEvent('开场'), AgentDoneEvent('开场')]),
    );
  }
}