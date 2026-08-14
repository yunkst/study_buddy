// ReviewSessionPage（翻转卡 + 四档评分）widget 测试。
//
// 目标（Task 6.3）：
// 1. 主流程：seed 1 张 due 卡 → 正面显示 question → tap 翻面显示 summary →
//    tap「良好」→ 完成视图「今日复习 1 张已完成」。
// 2. 新卡额度：seed 5 张 reps==0 且今天已首评过的卡 + 第 6 张 reps==0 due 卡 →
//    评第 1 张时 firstGradeCountToday(now)=5 ≥ kDailyNewCardCap → 被拒 →
//    SnackBar「今日新卡额度已用完，明天再来」+ 保持当前卡（不推进）。
//
// 测试基础设施（范式同 today_page_test / knowledge_page_test）：
// - sqflite_ffi in-memory 真建 db。DB open 与 seed(insert) 放在 setUp 的 real-async
//   zone（不在 testWidgets 的 fake-async zone，否则 isolate 结果回不来会永久挂起）。
// - seed 用 sdb.db.insert + Category/Topic/TopicSchedule.toMap 直插；topic_schedule
//   通过 topic_id 外键关联，故必须先建 category→topic→topic_schedule，topic 表
//   必须有对应行（ReviewTopicProvider 按 schedule.topicId 查 Topic）。
// - ReviewSessionPage 不触原生 channel；页面 onBack/context.go('/today') 需要 router 提供 /today 路由。
// - AppTheme.light 提供 PaperColors 扩展（_RatingRow/_CardView 依赖 accent/stampRed）。
// - sqflite 查询真实异步：先 pumpWidget 启动 FutureProvider，runAsync real zone 等 DB
//   查询，再回 fake zone pump。结束时 pump(11s) 清掉 txnSynchronized 遗留的一次性
//   lock-warning Timer，避免 teardown「Timer still pending」。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:study_buddy/core/providers/database_provider.dart';
import 'package:study_buddy/core/theme/app_theme.dart';
import 'package:study_buddy/core/theme/paper_extension.dart';
import 'package:study_buddy/features/review/review_session_page.dart';
import 'package:study_engine/study_engine.dart';

/// 建一个分类并返回其 id。
Future<int> _seedCategory(StudyDatabase sdb) async {
  return sdb.db.insert(
    'category',
    Category(name: '数学', createdAt: DateTime.now()).toMap(),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  setUp(() => SharedPreferences.setMockInitialValues({})); // dailyReviewLimitProvider 走 mock，默认 20

  late StudyDatabase sdb;

  setUp(() async {
    sdb = await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
  });
  tearDown(() async => await sdb.close());

  /// 装配 ProviderContainer：db override。
  ProviderContainer buildContainer() => ProviderContainer(overrides: [
        databaseProvider.overrideWith((ref) async => sdb),
      ]);

  /// 装配复习页：in-memory db + AppTheme.light + GoRouter。
  Future<void> pumpReviewPage(WidgetTester tester, ProviderContainer container) async {
    final router = GoRouter(
      initialLocation: '/review',
      routes: [
        GoRoute(
          path: '/review',
          builder: (context, state) => const ReviewSessionPage(),
        ),
        GoRoute(
          path: '/today',
          builder: (context, state) => const Scaffold(body: Center(child: Text('today'))),
        ),
      ],
    );

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        theme: AppTheme.light,
      ),
    ));
    // sqflite_ffi 查询真实异步（isolate），fake zone 不自动完成。先 pumpWidget 让
    // FutureProvider future 在 fake zone 启动，runAsync real zone 等 DB 查询，回 fake
    // zone pump 渲染 data 态。
    //
    // 两级 provider 各要一轮：queue 加载完成后卡体才第一次 watch reviewTopicProvider
    //（family），该 provider 会再触发一次 DB 查询；不补一轮 runAsync 会让 topic 停留
    // loading（无限 spinner），后续 pumpAndSettle 永不 settle。
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump(); // reviewQueueProvider → data，卡体开始 watch reviewTopicProvider
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('due 卡翻面 + 良好评分 → 完成视图', (tester) async {
    // seed（fake-async zone 内 DB insert 会用 isolate 结果回不来而挂起，故包 runAsync）。
    await tester.runAsync(() async {
      final now = DateTime.now();
      final catId = await _seedCategory(sdb);
      final topicId = await sdb.db.insert(
        'topic',
        Topic(
          categoryId: catId,
          question: '极限的定义',
          title: '极限的定义',
          summary: '答案为：极限的定义',
          createdAt: now,
          updatedAt: now,
        ).toMap(),
      );
      await sdb.db.insert(
        'topic_schedule',
        TopicSchedule(
          topicId: topicId,
          stability: 1.0,
          difficulty: 5.0,
          reps: 1, // 已是复习卡，不触发新卡额度
          lapses: 0,
          lastReviewedAt: now.subtract(const Duration(days: 10)),
          dueAt: now.subtract(const Duration(days: 1)),
        ).toMap(),
      );
    });

    final container = buildContainer();
    addTearDown(container.dispose);

    await pumpReviewPage(tester, container);

    // 正面：进度 + question（Markdown 渲染为 Text.rich，用 textContaining 断言）。
    expect(find.text('第 1 / 1 张'), findsOneWidget);
    expect(find.textContaining('极限的定义', findRichText: true), findsOneWidget);
    expect(find.text('点击翻面看答案'), findsOneWidget);

    // tap 翻面 → 显示 summary + 评分按钮。
    await tester.tap(find.text('点击翻面看答案'));
    await tester.pumpAndSettle();
    expect(find.textContaining('答案为：极限的定义', findRichText: true), findsOneWidget);
    expect(find.text('良好'), findsOneWidget);

    // tap「良好」→ gradeAndReview（reps!=0 不走新卡额度）→ next → done。
    await tester.tap(find.text('良好'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();

    // 完成视图。
    expect(find.text('今日已复习 1 张'), findsOneWidget);

    // 清掉 sqflite txnSynchronized 遗留的一次性 lock-warning Timer。
    await tester.pump(const Duration(seconds: 11));
  });

  testWidgets('新卡额度耗尽：评分被拒 + SnackBar + 不推进', (tester) async {
    // 5 张 reps==0 且 lastReviewedAt=today 的卡（firstGradeCountToday(now)=5，已满
    // 新卡额度）+ 第 6 张 reps==0 新卡。全部 due 已到 → 都进队列。评最顶上一张
    // （reps==0）时 firstGradeCountToday=5 ≥ kDailyNewCardCap → 被拒 + SnackBar。
    await tester.runAsync(() async {
      final now = DateTime.now();
      final catId = await _seedCategory(sdb);
      for (var i = 0; i < 5; i++) {
        final tid = await sdb.db.insert(
          'topic',
          Topic(
            categoryId: catId,
            question: '已首评卡 $i',
            title: '已首评卡 $i',
            summary: '答案为：已首评卡 $i',
            createdAt: now,
            updatedAt: now,
          ).toMap(),
        );
        await sdb.db.insert(
          'topic_schedule',
          TopicSchedule(
            topicId: tid,
            stability: 0.4,
            difficulty: 5.0,
            reps: 0,
            lapses: 0,
            lastReviewedAt: now,
            dueAt: now.subtract(Duration(hours: 1)),
          ).toMap(),
        );
      }
      final newTid = await sdb.db.insert(
        'topic',
        Topic(
          categoryId: catId,
          question: '全新卡',
          title: '全新卡',
          summary: '答案为：全新卡',
          createdAt: now,
          updatedAt: now,
        ).toMap(),
      );
      await sdb.db.insert(
        'topic_schedule',
        TopicSchedule(
          topicId: newTid,
          stability: 0.4,
          difficulty: 5.0,
          reps: 0,
          lapses: 0,
          dueAt: now.subtract(const Duration(hours: 1)),
        ).toMap(),
      );
    });

    final container = buildContainer();
    addTearDown(container.dispose);

    await pumpReviewPage(tester, container);

    // 队列应含 6 张，进度 第 1 / 6 张。
    expect(find.text('第 1 / 6 张'), findsOneWidget);

    // 翻面显示评分按钮。
    await tester.tap(find.text('点击翻面看答案'));
    await tester.pumpAndSettle();
    expect(find.text('良好'), findsOneWidget);

    // 评当前卡（reps==0）→ firstGradeCountToday(now)=5 ≥ 5 → 被拒。
    await tester.tap(find.text('良好'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();

    // SnackBar 提示 + 不推进（仍停在 第 1 / 6 张，完成视图未出现）。
    expect(find.text('今日新卡额度已用完，明天再来'), findsOneWidget);
    expect(find.text('第 1 / 6 张'), findsOneWidget);
    expect(find.text('今日已复习 6 张'), findsNothing);

    // 清掉 sqflite txnSynchronized 遗留的一次性 lock-warning Timer。
    await tester.pump(const Duration(seconds: 11));

    // 待 SnackBar 显示时间(4s)触发自动隐藏并跑完退出动画，避免 finalize 时报
    // 「animation is still running」。
    await tester.pumpAndSettle();
  });

  testWidgets('再来一组：评完一组后出现按钮，点按进入下一组首张', (tester) async {
    // 复习上限设 2（通过 SharedPreferences mock 注入）；seed 3 张 due 复习卡
    // （reps=1 避免触发新卡额度）。评完第 1 组（2 张）→ 完成态「再来一组」→
    // 点按 → setIndex=2，第 2 组取第 3 张（进度 第 1 / 1 张，累计 已复习 2 张）。
    SharedPreferences.setMockInitialValues({'daily_review_limit': 2});
    await tester.runAsync(() async {
      final now = DateTime.now();
      final catId = await _seedCategory(sdb);
      for (var i = 0; i < 3; i++) {
        final tid = await sdb.db.insert(
          'topic',
          Topic(
            categoryId: catId,
            question: '复习卡 $i',
            title: '复习卡 $i',
            summary: '答案为：复习卡 $i',
            createdAt: now,
            updatedAt: now,
          ).toMap(),
        );
        await sdb.db.insert(
          'topic_schedule',
          TopicSchedule(
            topicId: tid,
            stability: 1.0,
            difficulty: 5.0,
            reps: 1, // 复习卡，不走新卡额度
            lapses: 0,
            lastReviewedAt: now.subtract(const Duration(days: 10)),
            dueAt: now.subtract(const Duration(days: 1)),
          ).toMap(),
        );
      }
    });

    final container = buildContainer();
    addTearDown(container.dispose);

    await pumpReviewPage(tester, container);

    // 第 1 组：2 张。进度 第 1 / 2 张。
    expect(find.text('第 1 / 2 张'), findsOneWidget);

    // 评第 1 张。评完后要加载第 2 张（reviewTopicProvider family 新查询），
    // 故用「翻面 settle + 评分后两轮 runAsync+pump」等 DB 查询（见 pumpReviewPage 注释）。
    await tester.tap(find.text('点击翻面看答案'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('良好'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump(); // next 推进 → 卡体开始 watch 下一张 reviewTopicProvider
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // 评第 2 张 → 完成态（无新卡加载，pumpAndSettle 可用）。
    await tester.tap(find.text('点击翻面看答案'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('良好'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();

    // 完成视图：今日已复习 2 张 + 再来一组按钮。
    expect(find.text('今日已复习 2 张'), findsOneWidget);
    expect(find.text('再来一组'), findsOneWidget);

    // 点「再来一组」→ 第 2 组取第 3 张（skip(2).take(2) = 1 张），需加载该卡。
    await tester.tap(find.text('再来一组'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump(); // nextSet → 卡体开始 watch 第 3 张 reviewTopicProvider
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // 新组首张：进度 第 1 / 1 张，累计提示「今日已复习 2 张」。
    expect(find.text('今日已复习 2 张'), findsOneWidget);
    expect(find.text('第 1 / 1 张'), findsOneWidget);

    await tester.pump(const Duration(seconds: 11));
  });

  // 回归：复习卡 4 档评分按钮（忘了/困难/良好/简单）使用「记忆牢固度色阶」——
  // 忘了→error（朱砂）、困难/良好→paper.gold（提示金）、简单→tertiary（墨绿），
  // 每档按钮文字与该档语义色一致（淡色底 + 同色边框，对比充足）。
  // 替代旧设计：扁平 tonal 按钮 + onSecondaryContainer 文字。
  testWidgets('4 档评分按钮按记忆牢固度使用语义色', (tester) async {
    await tester.runAsync(() async {
      final now = DateTime.now();
      final catId = await _seedCategory(sdb);
      final topicId = await sdb.db.insert(
        'topic',
        Topic(
          categoryId: catId,
          question: '色相配对',
          title: '色相配对',
          summary: '答案为：色相配对',
          createdAt: now,
          updatedAt: now,
        ).toMap(),
      );
      await sdb.db.insert(
        'topic_schedule',
        TopicSchedule(
          topicId: topicId,
          stability: 1.0,
          difficulty: 5.0,
          reps: 1,
          lapses: 0,
          lastReviewedAt: now.subtract(const Duration(days: 10)),
          dueAt: now.subtract(const Duration(days: 1)),
        ).toMap(),
      );
    });

    final container = buildContainer();
    addTearDown(container.dispose);
    await pumpReviewPage(tester, container);

    // 翻面：显示 4 档评分按钮。
    await tester.tap(find.text('点击翻面看答案'));
    await tester.pumpAndSettle();

    final cs = AppTheme.light.colorScheme;
    final gold = AppTheme.light.extension<PaperColors>()!.gold;
    final expected = <String, Color>{
      '忘了': cs.error,
      '困难': gold,
      '良好': gold,
      '简单': cs.tertiary,
    };
    for (final entry in expected.entries) {
      final text = tester.widget<Text>(find.text(entry.key));
      expect(
        text.style?.color,
        entry.value,
        reason: '「${entry.key}」文字颜色应为其语义色 ${entry.value}，'
            '与淡色底（语义色 12% 透明度）同色系配对、对比充足。',
      );
    }

    await tester.pump(const Duration(seconds: 11));
  });
}