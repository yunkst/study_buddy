// 知识 Tab 长按删除的 widget 测试。
//
// 覆盖：
// 1. 长按分类行 → 弹「删除 X」确认对话框（含影响范围）。
// 2. 确认删除后分类及子树知识点被删除（db 验证 + UI 空态）。
// 3. 取消删除则数据保留。
// 4. 长按知识点行 → 弹确认；确认后知识点消失。
//
// 时序要点（严格对齐 knowledge_page_test / topic_detail_page_test）：
// - sqflite_ffi 查询/事务在真实 isolate 跑，fake-async zone 不会自动推进 →
//   必须用 tester.runAsync 等待；db 断言也必须在 runAsync 内做，否则永久挂起。
// - dialog 开合动画有限时长，可 pumpAndSettle；但删除后 invalidate 触发 UI 进入
//   loading（CircularProgressIndicator 无限动画），pumpAndSettle 会永不返回 →
//   删除后的等待用 runAsync + 固定次数 pump，不用 pumpAndSettle。
// - 末尾 pump(11s) 消化 sqflite txnSynchronized 的 10s lock-warning Timer。
library;

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
  late int mathId;
  late int advancedId;
  late int squeezeId;

  setUp(() async {
    sdb = await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final now = DateTime.now();
    mathId = await sdb.db.insert('category',
        Category(parentId: null, name: '数学', createdAt: now).toMap());
    advancedId = await sdb.db.insert('category',
        Category(parentId: mathId, name: '高等数学', createdAt: now).toMap());
    await sdb.db.insert('category',
        Category(parentId: advancedId, name: '极限', createdAt: now).toMap());
    // 洛必达挂在「高等数学」下；夹逼定理挂在「数学」直接下。
    await sdb.db.insert('topic', Topic(
      categoryId: advancedId,
      question: 'q',
      title: '洛必达法则',
      summary: 's',
      createdAt: now,
      updatedAt: now,
    ).toMap());
    squeezeId = await sdb.db.insert('topic', Topic(
      categoryId: mathId,
      question: 'q',
      title: '夹逼定理',
      summary: 's',
      createdAt: now,
      updatedAt: now,
    ).toMap());
  });
  tearDown(() async => await sdb.close());

  /// real zone 等 isolate 工作完成（sqflite 查询/事务）。
  Future<void> waitReal(WidgetTester tester) =>
      tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 600)));

  /// 通用 settle：runAsync 等 isolate（含 loading→data 切换）+ 多次 pump 推进 rebuild。
  /// 刻意不用 pumpAndSettle——loading 的 CircularProgressIndicator 是无限动画，
  /// pumpAndSettle 会判定「永远有 pending 帧」而超时。
  Future<void> settle(WidgetTester tester) async {
    await waitReal(tester);
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// 轮询等待：反复 runAsync 等 isolate + pump 推进 rebuild，直到 [cond] 满足。
  /// 用于「invalidate 后 UI 重建」「下钻后列表出现」这类无法预知 pump 次数的情况。
  /// 超过 [max] 次仍未满足则抛错（保留最后状态供调试）。
  Future<void> pumpUntil(
    WidgetTester tester,
    bool Function() cond, {
    int max = 60,
    String? reason,
  }) async {
    for (var i = 0; i < max; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 100));
      if (cond()) return;
    }
    throw TestFailure('pumpUntil 超时未满足条件${reason == null ? '' : ': $reason'}');
  }

  /// 首屏装配：pumpWidget → settle（首屏 isolate 查询 + 首帧渲染）。
  Future<void> pumpKnowledgePage(WidgetTester tester, ProviderContainer container) async {
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(theme: AppTheme.light, home: const KnowledgePage()),
    ));
    await settle(tester);
  }

  /// 在 real zone 里执行 db 断言（否则 fake zone 直接 await sqflite 会挂起）。
  Future<void> expectInReal(WidgetTester tester, Future<void> Function() body) async {
    await tester.runAsync(body);
  }

  /// 收尾：pump(11s) 消化 lock timer + 清空 widget 树。
  Future<void> teardownWidget(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 11));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }

  testWidgets('长按分类行弹出删除确认对话框（含影响范围）', (tester) async {
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWith((ref) async => sdb),
    ]);
    addTearDown(container.dispose);

    await pumpKnowledgePage(tester, container);
    await tester.longPress(find.text('数学'));
    await settle(tester);

    expect(find.text('删除「数学」'), findsOneWidget);
    expect(find.textContaining('子分类'), findsOneWidget);
    expect(find.textContaining('不可撤销'), findsOneWidget);

    // 关闭弹窗，保持测试自洽。
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await settle(tester);
    await teardownWidget(tester);
  });

  testWidgets('确认删除分类后该分类与子树知识点被删除', (tester) async {
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWith((ref) async => sdb),
    ]);
    addTearDown(container.dispose);

    await pumpKnowledgePage(tester, container);
    expect(find.text('数学'), findsOneWidget);

    await tester.longPress(find.text('数学'));
    await settle(tester);

    await tester.tap(find.widgetWithText(FilledButton, '删除'));

    // db 验证（real zone）：删除事务完成。
    await expectInReal(tester, () async {
      final cats = await CategoryRepository(sdb).findChildren(null);
      expect(cats.where((c) => c.name == '数学'), isEmpty);
      expect(await sdb.db.query('topic'), isEmpty);
    });

    // UI 验证：invalidate 重建后根视图已无「数学」（轮询等待重建完成）。
    await pumpUntil(tester, () => find.text('数学').evaluate().isEmpty,
        reason: '删除后「数学」应从根视图消失');

    await teardownWidget(tester);
  });

  testWidgets('取消删除则分类保留', (tester) async {
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWith((ref) async => sdb),
    ]);
    addTearDown(container.dispose);

    await pumpKnowledgePage(tester, container);
    await tester.longPress(find.text('数学'));
    await settle(tester);

    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await settle(tester);

    expect(find.text('数学'), findsOneWidget);
    await expectInReal(tester, () async {
      final cats = await CategoryRepository(sdb).findChildren(null);
      expect(cats.where((c) => c.name == '数学'), isNotEmpty);
    });

    await teardownWidget(tester);
  });

  testWidgets('长按知识点行弹出删除确认；确认后消失', (tester) async {
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWith((ref) async => sdb),
    ]);
    addTearDown(container.dispose);

    await pumpKnowledgePage(tester, container);
    // 点进「数学」（下钻后知识点列表出现，轮询等待 isolate 查询 + 渲染完成）。
    await tester.tap(find.text('数学'));
    await pumpUntil(tester, () => find.text('夹逼定理').evaluate().isNotEmpty,
        reason: '下钻后应显示「夹逼定理」');

    // 长按「夹逼定理」
    await tester.longPress(find.text('夹逼定理'));
    await settle(tester);
    expect(find.text('删除「夹逼定理」'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '删除'));

    // db 验证
    await expectInReal(tester, () async {
      final t = await TopicRepository(sdb).findById(squeezeId);
      expect(t, isNull);
    });
    // UI 验证：invalidate 重建后知识点行消失（轮询等待）。
    await pumpUntil(tester, () => find.text('夹逼定理').evaluate().isEmpty,
        reason: '删除后「夹逼定理」应从列表消失');

    await teardownWidget(tester);
  });
}