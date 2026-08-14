// RecommendTopicsCard widget 测试。
//
// 目标：
// 1. 渲染「相关知识点」标题与各 item 的标题/分类路径。
// 2. 掌握度标签：seed topic_schedule（stability=25 → mastered）→ 该行显示「已掌握」。
// 3. 点击 item → context.push('/topic/:id') 进详情页。
//
// 基础设施（范式同 saved_topic_capsule_test）：
// - sqflite_ffi in-memory 真建 db（masteryOfProvider 读 db），
//   DB seeding 放 setUp（真实 zone，非 testWidgets 的 fake-async zone）。
// - MaterialApp.router + 简单 GoRouter 提供 /topic/:id。
// - AppTheme.light 提供 PaperColors 扩展兜底。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:study_buddy/core/providers/database_provider.dart';
import 'package:study_buddy/core/theme/app_theme.dart';
import 'package:study_buddy/features/external_qbank/ai_panel_sheet.dart';
import 'package:study_buddy/features/external_qbank/recommend_topics_card.dart';
import 'package:study_engine/study_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  late StudyDatabase sdb;
  late int masteredTopicId;

  setUp(() async {
    sdb = await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    await sdb.db.insert('category', {'name': '数学', 'sort_order': 0, 'created_at': 0});
    final catId = (await sdb.db.query('category', limit: 1)).first['id'] as int;
    await sdb.db.insert('topic', {
      'category_id': catId,
      'question': 'q',
      'title': '洛必达法则',
      'summary': 's',
      'created_at': 0,
      'updated_at': 0,
    });
    masteredTopicId = (await sdb.db.query('topic', limit: 1)).first['id'] as int;
    await sdb.db.insert('topic_schedule', TopicSchedule(
      topicId: masteredTopicId,
      stability: 25, // ≥kMasteredStabilityThreshold(21) → mastered
      difficulty: 5,
      reps: 2,
      lapses: 0,
      lastReviewedAt: DateTime(2026, 8, 12),
    ).toMap());
  });
  tearDown(() async => await sdb.close());

  Future<void> pumpCard(
    WidgetTester tester,
    ProviderContainer container,
    Widget card,
  ) async {
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => Scaffold(body: card),
        ),
        GoRoute(
          path: '/topic/:id',
          builder: (context, state) =>
              const Scaffold(body: Center(child: Text('topic page'))),
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
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
  }

  ProviderContainer container() => ProviderContainer(overrides: [
        databaseProvider.overrideWith((ref) async => sdb),
      ]);

  const items = [
    RecommendTopicsItem(id: 1, title: '洛必达法则', path: '数学'),
    RecommendTopicsItem(id: 2, title: '未定式极限', path: '数学'),
  ];

  testWidgets('渲染「相关知识点」标题与各条目的 title/path', (tester) async {
    final c = container();
    addTearDown(c.dispose);

    await pumpCard(tester, c, const RecommendTopicsCard(items: items));

    expect(find.text('相关知识点'), findsOneWidget);
    expect(find.text('洛必达法则'), findsOneWidget);
    expect(find.text('未定式极限'), findsOneWidget);
    // 两条的 path 各渲染一次
    expect(find.text('数学'), findsNWidgets(2));
  });

  testWidgets('已掌握条目显示掌握度标签', (tester) async {
    final c = container();
    addTearDown(c.dispose);

    await pumpCard(
      tester,
      c,
      const RecommendTopicsCard(items: [
        RecommendTopicsItem(id: 1, title: '极限', path: '数学'),
      ]),
    );

    expect(find.text('已掌握'), findsOneWidget);
  });

  testWidgets('点击条目跳转 /topic/:id', (tester) async {
    final c = container();
    addTearDown(c.dispose);

    await pumpCard(tester, c, const RecommendTopicsCard(items: items));

    await tester.tap(find.text('洛必达法则'));
    await tester.pumpAndSettle();

    expect(find.text('topic page'), findsOneWidget);
  });

  group('buildToolResultWidget 渲染器', () {
    final cs = ThemeData.light().colorScheme;
    final theme = ThemeData.light();

    testWidgets('正常 items → RecommendTopicsCard', (tester) async {
      final w = buildToolResultWidget(
        name: 'recommend_topics',
        result: '{"items":[{"id":1,"title":"洛必达法则","path":"数学"}]}',
        line: '',
        colorScheme: cs,
        theme: theme,
      );
      expect(w, isA<RecommendTopicsCard>());
    });

    testWidgets('空 items → 回退普通轨迹行(非卡片)', (tester) async {
      final w = buildToolResultWidget(
        name: 'recommend_topics',
        result: '{"items":[]}',
        line: '',
        colorScheme: cs,
        theme: theme,
      );
      expect(w, isNot(isA<RecommendTopicsCard>()));
    });

    testWidgets('非法 JSON → 回退普通轨迹行', (tester) async {
      final w = buildToolResultWidget(
        name: 'recommend_topics',
        result: 'not-json',
        line: '',
        colorScheme: cs,
        theme: theme,
      );
      expect(w, isNot(isA<RecommendTopicsCard>()));
    });
  });
}