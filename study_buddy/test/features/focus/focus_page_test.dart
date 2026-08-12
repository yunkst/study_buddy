import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:study_buddy/core/providers/database_provider.dart';
import 'package:study_buddy/core/providers/focus_session_provider.dart';
import 'package:study_buddy/features/focus/focus_page.dart';
import 'package:study_engine/study_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  const channel = MethodChannel('study_buddy/focus');

  Future<void> mockChannel() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'isRunning') return false;
      return null;
    });
  }

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  // 预置一条真实会话，返回其真实 id（fake notifier 的 sessionId 用它，
  // 保证 DB 里确实存在该记录，query 能查到）。
  Future<int> seedSession(WidgetTester tester, StudyDatabase sdb) async {
    return (await tester.runAsync(
        () => FocusSessionRepository(sdb).start(DateTime(2026, 8, 12, 9, 0))))!;
  }

  // 用真实内存库 + fake notifier（无 tick，避免 Stream.periodic 卡死 pumpAndSettle）。
  // fake notifier 的 state 带 [sessionId]，stop() 只记标志不写库——「停止落库」属
  // provider 层职责（focus_session_provider_test 已覆盖），此处专注验证
  // 「弹框 → 输入 → DB summary 写入」这条新链路。
  //
  // 注意：真实 sqflite IO 必须包在 tester.runAsync 里（testWidgets 的 fake async
  // zone 不会推进真实异步），否则 DB open / 读写 future 永不完成导致测试卡死。
  Future<ProviderContainer> pumpFocusPage(
    WidgetTester tester,
    StudyDatabase sdb,
    int sessionId,
  ) async {
    final c = ProviderContainer(overrides: [
      databaseProvider.overrideWith((ref) async => sdb),
      focusSessionProvider.overrideWith((ref) => _FakeNotifier(ref,
          state: FocusSessionState(sessionId: sessionId, running: true))),
    ]);
    addTearDown(c.dispose);
    // 预 resolve databaseProvider，避免 tap 触发真实 DB open 卡死
    await tester.runAsync(() => c.read(databaseProvider.future));
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: const MaterialApp(home: FocusPage()),
    ));
    return c;
  }

  Future<StudyDatabase> openSdb(WidgetTester tester) async {
    final sdb = await tester.runAsync(() => StudyDatabase.open(
        factory: databaseFactoryFfi, path: inMemoryDatabasePath));
    addTearDown(() async => await sdb!.close());
    return sdb!;
  }

  testWidgets('idle 态显示开始按钮', (tester) async {
    final container = ProviderContainer(overrides: [
      focusSessionProvider.overrideWith((ref) => _FakeNotifier(ref)),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: FocusPage()),
    ));

    expect(find.text('开始专注'), findsOneWidget);
    expect(find.text('结束专注'), findsNothing);
  });

  testWidgets('running 态显示结束按钮与计时', (tester) async {
    final container = ProviderContainer(overrides: [
      focusSessionProvider.overrideWith((ref) =>
          _FakeNotifier(ref, state: const FocusSessionState(
            sessionId: 1, running: true, elapsed: Duration(minutes: 5, seconds: 3),
          ))),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: FocusPage()),
    ));

    expect(find.text('结束专注'), findsOneWidget);
    expect(find.text('开始专注'), findsNothing);
    expect(find.text('00:05:03'), findsOneWidget);
  });

  testWidgets('点开始按钮调用 start', (tester) async {
    final container = ProviderContainer(overrides: [
      focusSessionProvider.overrideWith((ref) => _FakeNotifier(ref)),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: FocusPage()),
    ));

    await tester.tap(find.text('开始专注'));
    await tester.pump();
    final notifier = container.read(focusSessionProvider.notifier) as _FakeNotifier;
    expect(notifier.startCalled, isTrue);
  });

  testWidgets('结束专注：弹框输入→保存→DB summary 写入且 stop 被调用', (tester) async {
    await mockChannel();
    final sdb = await openSdb(tester);
    final sessionId = await seedSession(tester, sdb);
    final container = await pumpFocusPage(tester, sdb, sessionId);

    // 点「结束专注」→ 弹框（Dialog 动画用显式 pump 推进，不用 pumpAndSettle）
    await tester.tap(find.text('结束专注'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('这段时间做了什么？'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '复习了洛必达法则，刷了十道极限题');
    await tester.pump();
    await tester.tap(find.text('保存'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 让真实 DB 写入（setSummary）在 runAsync 中完成
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();

    final rows = await tester.runAsync(
        () => sdb.db.query('focus_session', where: 'id = ?', whereArgs: [sessionId]));
    expect(rows!.first['summary'], '复习了洛必达法则，刷了十道极限题');
    final notifier = container.read(focusSessionProvider.notifier) as _FakeNotifier;
    expect(notifier.stopCalled, isTrue);
  });

  testWidgets('结束专注：点跳过→不写 summary 但 stop 被调用', (tester) async {
    await mockChannel();
    final sdb = await openSdb(tester);
    final sessionId = await seedSession(tester, sdb);
    final container = await pumpFocusPage(tester, sdb, sessionId);

    await tester.tap(find.text('结束专注'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('跳过'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final rows = await tester.runAsync(
        () => sdb.db.query('focus_session', where: 'id = ?', whereArgs: [sessionId]));
    expect(rows!.first['summary'], isNull);
    final notifier = container.read(focusSessionProvider.notifier) as _FakeNotifier;
    expect(notifier.stopCalled, isTrue);
  });

  testWidgets('结束专注：保存空文本→不写 summary 但 stop 被调用', (tester) async {
    await mockChannel();
    final sdb = await openSdb(tester);
    final sessionId = await seedSession(tester, sdb);
    final container = await pumpFocusPage(tester, sdb, sessionId);

    await tester.tap(find.text('结束专注'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 不输入直接点保存（空文本，trim 后为空 → 不写）
    await tester.tap(find.text('保存'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final rows = await tester.runAsync(
        () => sdb.db.query('focus_session', where: 'id = ?', whereArgs: [sessionId]));
    expect(rows!.first['summary'], isNull);
    final notifier = container.read(focusSessionProvider.notifier) as _FakeNotifier;
    expect(notifier.stopCalled, isTrue);
  });
}

class _FakeNotifier extends FocusSessionNotifier {
  _FakeNotifier(super.ref, {FocusSessionState? state}) {
    if (state != null) this.state = state;
  }
  bool startCalled = false;
  bool stopCalled = false;
  @override
  Future<void> start() async { startCalled = true; }
  @override
  Future<void> stop() async { stopCalled = true; }
}