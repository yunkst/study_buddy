// 知识 Tab：嵌套分类下钻测试（Task：主修"agent 创建的知识点浏览不到"）。
//
// 背景：agent 的 save_topic 按系统提示词把知识点挂到多层嵌套分类（如
// 数学/高等数学/极限），而知识页 _buildSelectedCategory 只显示直挂知识点、
// 没有子分类入口，导致嵌套分类下的知识点浏览不可达（搜索可达）。
// 本测试锁定修复：点进分类应渲染子分类入口，支持无限层下钻。
//
// 测试基础设施与范式同 knowledge_page_test.dart：
// - sqflite_ffi in-memory 真建空 db，seed 在 setUp 的 real-async zone。
// - seed 直接用 sdb.db.insert + Category/Topic 的 toMap。
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
  late int mathCategoryId; // 顶级「数学」
  late int calcCategoryId; // 「数学/高等数学」

  setUp(() async {
    sdb = await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final now = DateTime.now();
    mathCategoryId = await sdb.db.insert(
      'category',
      Category(parentId: null, name: '数学', createdAt: now).toMap(),
    );
    calcCategoryId = await sdb.db.insert(
      'category',
      Category(parentId: mathCategoryId, name: '高等数学', createdAt: now).toMap(),
    );
    // 知识点只挂在「高等数学」下（模拟 agent 挂到最具体分类）。
    await sdb.db.insert(
      'topic',
      Topic(
        categoryId: calcCategoryId,
        question: 'ε-δ 极限定义是什么？',
        title: 'ε-δ 极限定义',
        summary: '对任意 ε>0，存在 δ>0，使得 0<|x-a|<δ 时 |f(x)-L|<ε。',
        createdAt: now,
        updatedAt: now,
      ).toMap(),
    );
  });
  tearDown(() async => await sdb.close());

  Future<void> pumpKnowledgePage(WidgetTester tester, ProviderContainer container) async {
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.light,
        home: const KnowledgePage(),
      ),
    ));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  /// 点进「数学」分类并完成其 FutureProvider 查询。
  Future<void> enterMath(WidgetTester tester) async {
    await tester.tap(find.text('数学'));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump();
    await tester.pumpAndSettle();
  }

  /// 清掉 sqflite txnSynchronized 留下的 pending Timer（同 knowledge_page_test）。
  Future<void> drainTimers(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 11));
  }

  testWidgets('点进「数学」显示子分类「高等数学」入口', (tester) async {
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWith((ref) async => sdb),
    ]);
    addTearDown(container.dispose);

    await pumpKnowledgePage(tester, container);
    await enterMath(tester);

    // 子分类入口可见（当前实现缺失 → 失败）。
    expect(find.text('高等数学'), findsOneWidget);
    await drainTimers(tester);
  });

  testWidgets('下钻到「高等数学」显示其知识点', (tester) async {
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWith((ref) async => sdb),
    ]);
    addTearDown(container.dispose);

    await pumpKnowledgePage(tester, container);
    await enterMath(tester);
    await tester.tap(find.text('高等数学'));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('ε-δ 极限定义'), findsOneWidget);
    await drainTimers(tester);
  });

  testWidgets('有子分类且无直挂知识点时不显示空态提示', (tester) async {
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWith((ref) async => sdb),
    ]);
    addTearDown(container.dispose);

    await pumpKnowledgePage(tester, container);
    await enterMath(tester);

    // 「数学」没有直挂知识点，但有子分类「高等数学」可下钻 → 不该提示空态。
    expect(find.text('该分类暂无知识点'), findsNothing);
    await drainTimers(tester);
  });
}
