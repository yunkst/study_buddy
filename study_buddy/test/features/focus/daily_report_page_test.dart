import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:study_buddy/core/providers/database_provider.dart';
import 'package:study_buddy/features/focus/daily_report_page.dart';
import 'package:study_engine/study_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  late StudyDatabase sdb;

  setUp(() async {
    sdb = await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
  });
  tearDown(() async => await sdb.close());

  Future<void> seedSession({
    required int startHour, required int endHour, required List<String> topicTitles,
  }) async {
    final focusRepo = FocusSessionRepository(sdb);
    final topicRepo = TopicRepository(sdb);
    final cats = CategoryRepository(sdb);
    final catId = await cats.ensurePath(['数学']);
    final now = DateTime(2026, 8, 10);
    final id = await focusRepo.start(DateTime(2026, 8, 10, startHour));
    final dur = (endHour - startHour) * 3600000;
    await focusRepo.end(id, DateTime(2026, 8, 10, endHour), dur);
    for (final title in topicTitles) {
      final tid = await topicRepo.insert(Topic(
        categoryId: catId, question: 'q', title: title, summary: 's',
        createdAt: now, updatedAt: now,
      ));
      await focusRepo.linkTopic(id, tid);
    }
  }

  /// sqflite_ffi 的查询是真实异步(基于 isolate),在 testWidgets 的
  /// fake-async zone 中不会自动完成。先 pumpWidget 让 FutureBuilder 的
  /// future 在 fake zone 启动,再在 runAsync 的 real zone 等待查询完成,
  /// 最后回 fake zone pumpAndSettle 让 FutureBuilder 重建为数据态。
  Future<void> pumpPage(WidgetTester tester, ProviderContainer container) async {
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: DailyReportPage(initialDate: DateTime(2026, 8, 10))),
    ));
    // 真实 DB IO 在 real zone 完成
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    // 回 fake zone 推进帧:FutureBuilder 重建,loading 动画消失
    await tester.pumpAndSettle();
  }

  testWidgets('空日报显示空态文案', (tester) async {
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWith((ref) async {
        return sdb;
      }),
    ]);
    addTearDown(container.dispose);
    await pumpPage(tester, container);

    expect(find.textContaining('没有专注记录'), findsOneWidget);
  });

  testWidgets('有数据时显示总用时/会话时间范围/知识点', (tester) async {
    await tester.runAsync(() async {
      await seedSession(startHour: 9, endHour: 10, topicTitles: ['极限', '导数']);
      await seedSession(startHour: 14, endHour: 15, topicTitles: ['连续']);
    });

    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWith((ref) async {
        return sdb;
      }),
    ]);
    addTearDown(container.dispose);
    await pumpPage(tester, container);

    // 总用时 2 小时
    expect(find.textContaining('2小时'), findsOneWidget);
    // 会话时间范围
    expect(find.textContaining('09:00–10:00'), findsOneWidget);
    expect(find.textContaining('14:00–15:00'), findsOneWidget);
    // 知识点
    expect(find.text('极限'), findsOneWidget);
    expect(find.text('导数'), findsOneWidget);
    expect(find.text('连续'), findsOneWidget);
  });
}
