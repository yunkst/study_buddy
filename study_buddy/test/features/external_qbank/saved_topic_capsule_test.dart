// SavedTopicCapsule widget 测试。
//
// 目标（task-7.1-brief）：
// 1. isNew=true → 显示朱砂「新」badge。
// 2. isNew=false 且 seed topic_schedule（stability=25 → mastered）→ 显示「已掌握」。
//
// 基础设施（范式同 today_page_test / topic_schedule_repository_test）：
// - sqflite_ffi in-memory 真建 db（masteryOfProvider 读 db）。
//   DB seeding 放在 setUp（真实 zone，非 testWidgets 的 fake-async zone），
//   与 topic_schedule_repository_test 的 seeding 方式一致。
// - capsule 内部用 go_router context.push：包 MaterialApp.router +
//   简单 GoRouter 提供 /topic/:id，避免运行时报错。
// - AppTheme.light 提供 PaperColors 扩展（stampRed/ruleSoft/polaroidBg 兜底）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:study_buddy/core/providers/database_provider.dart';
import 'package:study_buddy/core/theme/app_theme.dart';
import 'package:study_buddy/features/external_qbank/saved_topic_capsule.dart';
import 'package:study_engine/study_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  late StudyDatabase sdb;
  late int seededTopicId;

  setUp(() async {
    sdb = await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    // 建一个分类 + 一个 topic + stability=25 的 schedule（→ mastered）。
    // 范式同 topic_schedule_repository_test：真实 zone 内直接落库。
    await sdb.db.insert('category', {'name': '数学', 'sort_order': 0, 'created_at': 0});
    final catId = (await sdb.db.query('category', limit: 1)).first['id'] as int;
    await sdb.db.insert('topic', {
      'category_id': catId,
      'question': 'q',
      'title': '极限',
      'summary': 's',
      'created_at': 0,
      'updated_at': 0,
    });
    seededTopicId = (await sdb.db.query('topic', limit: 1)).first['id'] as int;
    await sdb.db.insert('topic_schedule', TopicSchedule(
      topicId: seededTopicId,
      stability: 25, // ≥kMasteredStabilityThreshold(21) → mastered
      difficulty: 5,
      reps: 2,
      lapses: 0,
      lastReviewedAt: DateTime(2026, 8, 12),
    ).toMap());
  });
  tearDown(() async => await sdb.close());

  /// 装配：in-memory db + AppTheme.light + MaterialApp.router 提供 /topic/:id。
  ///
  /// capsule 用 [Widget] 传入并由初始路由渲染（不能用 home，因为
  /// MaterialApp.router 没有 home 参数；用 GoRoute path='/' builder）。
  Future<void> pumpCapsule(
    WidgetTester tester,
    ProviderContainer container,
    Widget capsule,
  ) async {
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => Scaffold(body: capsule),
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
    // sqflite_ffi 查询是真实异步（isolate），fake-async zone 不会自动完成：
    // 先 pumpWidget 启动 FutureProvider，runAsync real zone 等 DB 查询，再 pumpAndSettle。
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
  }

  testWidgets('isNew=true → 显示「新」badge', (tester) async {
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWith((ref) async => sdb),
    ]);
    addTearDown(container.dispose);

    await pumpCapsule(
      tester,
      container,
      const SavedTopicCapsule(id: 1, isNew: true),
    );

    expect(find.text('新'), findsOneWidget);
  });

  testWidgets('已有(mastered) → 显示「已掌握」', (tester) async {
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWith((ref) async => sdb),
    ]);
    addTearDown(container.dispose);

    await pumpCapsule(
      tester,
      container,
      SavedTopicCapsule(id: seededTopicId, isNew: false),
    );

    expect(find.text('已掌握'), findsOneWidget);
  });
}