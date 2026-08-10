import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:study_buddy/core/providers/database_provider.dart';
import 'package:study_buddy/core/providers/focus_session_provider.dart';
import 'package:study_engine/study_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  late StudyDatabase sdb;
  const channel = MethodChannel('study_buddy/focus');
  late List<MethodCall> bridgeCalls;

  setUp(() async {
    sdb = await StudyDatabase.open(
        factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    bridgeCalls = [];
    // 注：用 TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
    // 而非 brief 中的 ServicesBinding.instance.defaultBinaryMessenger——后者静态
    // 类型 BinaryMessenger 无 setMockMethodCallHandler（Flutter API 迁移坑），
    // 与 Task 7 focus_timer_bridge_test.dart 一致。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      channel,
      (call) async {
        bridgeCalls.add(call);
        if (call.method == 'isRunning') return false;
        return null;
      },
    );
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await sdb.close();
  });

  ProviderContainer makeContainer() {
    final c = ProviderContainer(overrides: [
      databaseProvider.overrideWith((ref) async {
        // 注：close 所有权归 tearDown 的 sdb.close()，此处不再注册 onDispose
        // 重复 close——保持单一所有权（见任务说明第 3 点）。
        return sdb;
      }),
    ]);
    addTearDown(c.dispose);
    return c;
  }

  test('初始状态为 idle', () {
    final container = makeContainer();
    final state = container.read(focusSessionProvider);
    expect(state.running, isFalse);
    expect(state.sessionId, isNull);
    expect(state.elapsed, Duration.zero);
  });

  test('start 后进入 running 并落库 + 调原生 start', () async {
    final container = makeContainer();
    final notifier = container.read(focusSessionProvider.notifier);
    await notifier.start();
    await Future.delayed(const Duration(milliseconds: 50));

    final state = container.read(focusSessionProvider);
    expect(state.running, isTrue);
    expect(state.sessionId, isNotNull);
    // 落库
    final repo = FocusSessionRepository(sdb);
    final open = await repo.findOpenSession();
    expect(open, isNotNull);
    // 调原生
    expect(bridgeCalls.any((c) => c.method == 'start'), isTrue);

    await notifier.stop();
  });

  test('stop 后回到 idle 并写 ended_at/duration', () async {
    final container = makeContainer();
    final notifier = container.read(focusSessionProvider.notifier);
    await notifier.start();
    await Future.delayed(const Duration(milliseconds: 50));
    await notifier.stop();

    final state = container.read(focusSessionProvider);
    expect(state.running, isFalse);
    expect(state.sessionId, isNull);
    // DB 会话已结束
    final repo = FocusSessionRepository(sdb);
    expect(await repo.findOpenSession(), isNull);
    // 调原生 stop
    expect(bridgeCalls.any((c) => c.method == 'stop'), isTrue);
  });

  test('running 态再次 start 被拦截', () async {
    final container = makeContainer();
    final notifier = container.read(focusSessionProvider.notifier);
    await notifier.start();
    final firstId = container.read(focusSessionProvider).sessionId;
    await notifier.start(); // 应被拦截
    expect(container.read(focusSessionProvider).sessionId, firstId);
    await notifier.stop();
  });

  test('非 running 态 stop 无副作用', () async {
    final container = makeContainer();
    final notifier = container.read(focusSessionProvider.notifier);
    bridgeCalls.clear();
    await notifier.stop(); // 不应抛、不应调原生
    expect(bridgeCalls, isEmpty);
    expect(container.read(focusSessionProvider).running, isFalse);
  });

  test('recoverOrphan 清理 DB 残留会话（原生未跑）', () async {
    // 预置一个未结束会话
    final repo = FocusSessionRepository(sdb);
    await repo.start(DateTime(2026, 8, 10, 9, 0));

    final container = makeContainer();
    final notifier = container.read(focusSessionProvider.notifier);
    await notifier.recoverOrphan();
    // 应补结束
    expect(await repo.findOpenSession(), isNull);
    expect(container.read(focusSessionProvider).running, isFalse);
  });

  test('recoverOrphan 恢复分支:原生在跑则恢复 running + offset 重算', () async {
    // 预置未结束会话（用过去时间，保证 offset 非零）
    final repo = FocusSessionRepository(sdb);
    final startedAt = DateTime.now().subtract(const Duration(minutes: 5));
    await repo.start(startedAt);

    // 该测试让 isRunning 返回 true（覆盖恢复分支）
    // 注：setUp 设的全局 mock 固定返回 false，此处单独覆盖 handler。
    // tearDown 会 setMock 为 null 清理，无需在此手动恢复。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'isRunning') return true;
      return null;
    });

    final container = makeContainer();
    final notifier = container.read(focusSessionProvider.notifier);
    await notifier.recoverOrphan();

    final state = container.read(focusSessionProvider);
    expect(state.running, isTrue);
    expect(state.sessionId, isNotNull);
    // offset 至少 5 分钟
    expect(state.elapsed.inMinutes, greaterThanOrEqualTo(5));
    await notifier.stop();
  });

  test('start 后 tick 每秒推进 elapsed', () async {
    final container = makeContainer();
    final notifier = container.read(focusSessionProvider.notifier);
    await notifier.start();
    // tick 周期 1s，等 ≥1100ms 让首个 tick 触发
    await Future.delayed(const Duration(milliseconds: 1100));
    final state = container.read(focusSessionProvider);
    expect(state.elapsed.inSeconds, greaterThanOrEqualTo(1));
    await notifier.stop();
  });
}
