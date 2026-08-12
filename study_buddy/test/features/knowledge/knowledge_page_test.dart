// 知识 Tab：分类树下钻 + 知识点行、掌握度标签测试。
//
// 目标（Task 5.3）：
// 1. 顶层显示顶级分类「数学」。
// 2. 点进「数学」→ 显示知识点「夹逼定理」+ 掌握度标签「未学」（未排期 → unknown）。
//
// 测试基础设施与关键范式：
// - sqflite_ffi in-memory 真建空 db。DB 的 open 与 seed(insert) 必须放在 setUp 的
//   real-async zone（与 today_page_test 一致）；若在 testWidgets 体内直接
//   `await sdb.db.insert(...)`，sqflite_ffi 的 isolate 结果无法回到 fake-async zone，
//   会永久挂起。
// - seed 直接用 sdb.db.insert + Category/Topic 的 toMap，避开 repos。
// - KnowledgePage 不触 overlay channel，无需 mock `study_buddy/overlay`。
// - AppTheme.light 提供 PaperColors 扩展（_MasteryChip/_TopicRow 依赖 ruleSoft）。
// - _MasteryChip 为本文件私有组件，只能经显示文本「未学」断言，无法 import 内部。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:study_buddy/core/providers/database_provider.dart';
import 'package:study_buddy/core/theme/app_theme.dart';
import 'package:study_buddy/features/knowledge/knowledge_page.dart';
import 'package:study_engine/study_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  late StudyDatabase sdb;

  // setUp 中 seed 的分类 id（顶级「数学」），测试体复用。
  late int mathCategoryId;

  setUp(() async {
    sdb = await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final now = DateTime.now();
    // seed 顶级分类「数学」(parent_id 为空)。
    mathCategoryId = await sdb.db.insert(
      'category',
      Category(parentId: null, name: '数学', createdAt: now).toMap(),
    );
    // seed 其下知识点「夹逼定理」。刻意不写 topic_schedule：
    // masteryOfProvider 派生 unknown →「未学」。
    await sdb.db.insert(
      'topic',
      Topic(
        categoryId: mathCategoryId,
        question: '夹逼定理的内容？',
        title: '夹逼定理',
        summary: '夹逼定理：若两边收敛于同一极限，则中间序列亦收敛之。',
        createdAt: now,
        updatedAt: now,
      ).toMap(),
    );
  });
  tearDown(() async => await sdb.close());

  /// 装配知识页：in-memory db + AppTheme。
  Future<void> pumpKnowledgePage(WidgetTester tester, ProviderContainer container) async {
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.light,
        home: const KnowledgePage(),
      ),
    ));
    // sqflite_ffi 的查询是真实异步(基于 isolate)，在 testWidgets 的 fake-async zone 中
    // 不会自动完成：先 pumpWidget 让 FutureProvider 的 future 在 fake zone 启动，
    // 再在 runAsync 的 real zone 等待 DB 查询完成，随后回 fake zone pump 让 widget
    // 重建为 data 态。不用 pumpAndSettle，避免 loading 态 CircularProgressIndicator
    // 无限动画导致永不 settle。
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('顶层显示「数学」分类', (tester) async {
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWith((ref) async => sdb),
    ]);
    addTearDown(container.dispose);

    await pumpKnowledgePage(tester, container);

    // _buildRootCategories 的顶级分类行含「数学」，且仅一处。
    expect(find.text('数学'), findsOneWidget);
  });

  testWidgets('点进分类显示「夹逼定理」+「未学」标签', (tester) async {
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWith((ref) async => sdb),
    ]);
    addTearDown(container.dispose);

    await pumpKnowledgePage(tester, container);

    // 找到并点进「数学」分类行。
    await tester.tap(find.text('数学'));
    // tap 后先 pump 触发 rebuild：_buildSelectedCategory 才开始 watch
    // topicsInCategoryProvider/masteryOfProvider/_scheduleOfProvider，
    // 这些 FutureProvider 的 future 在此刻才被创建。
    await tester.pump();
    // 再回 real zone 等 DB 查询完成，最后 pump/pumpAndSettle 渲染 data 态
    // 并清掉 sqflite txnSynchronized 留下的 pending Timer 避免 teardown 报错。
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump();
    await tester.pumpAndSettle();
    // 下钻后 topicsInCategory/mastery/schedule 三路查询走 sqflite txnSynchronized，
    // 会在 fake zone 留下一个 10s 的 lock-warning timeout Timer。pumpAndSettle 只
    // 推进到无帧调度即停，不会触碰 pending Timer；这里显式推进 fake time 让该
    // 一次性 Timer 到期（onTimeout 仅打印告警，无害），避免 teardown「Timer still
    // pending」断言失败。
    await tester.pump(const Duration(seconds: 11));

    // 下钻后显示知识点标题 + 掌握度标签「未学」。
    expect(find.text('夹逼定理'), findsOneWidget);
    expect(find.text('未学'), findsOneWidget);
  });
}