import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:study_engine/study_engine.dart';

import 'database_provider.dart';
import 'focus_timer_bridge.dart';

/// 专注会话状态。running=false 即 idle（无进行中会话）。
class FocusSessionState {
  final int? sessionId;
  final DateTime? startedAt;
  final Duration elapsed;
  final bool running;
  const FocusSessionState({
    this.sessionId,
    this.startedAt,
    this.elapsed = Duration.zero,
    this.running = false,
  });
  static const idle = FocusSessionState();

  FocusSessionState copyWith({
    int? sessionId,
    DateTime? startedAt,
    Duration? elapsed,
    bool? running,
    bool clearSession = false,
  }) =>
      FocusSessionState(
        sessionId: clearSession ? null : (sessionId ?? this.sessionId),
        startedAt: clearSession ? null : (startedAt ?? this.startedAt),
        elapsed: elapsed ?? this.elapsed,
        running: running ?? this.running,
      );
}

/// 专注计时状态机。计时主源在本 Notifier（Stopwatch），原生通知栏为镜像。
class FocusSessionNotifier extends StateNotifier<FocusSessionState> {
  FocusSessionNotifier(this._ref) : super(FocusSessionState.idle);
  final Ref _ref;
  Stopwatch? _stopwatch;
  StreamSubscription<Duration>? _tick;

  /// 开始专注。守卫：已在 running 态直接 return。
  Future<void> start() async {
    if (state.running) return;
    final db = await _ref.read(databaseProvider.future);
    final repo = FocusSessionRepository(db);
    final now = DateTime.now();
    final id = await repo.start(now);

    final bridge = _ref.read(focusTimerBridgeProvider);
    try {
      await bridge.start(id);
    } catch (_) {
      // 通知栏启动失败不阻断计时（降级：app 内仍计时）
    }

    _stopwatch = Stopwatch()..start();
    state = FocusSessionState(
      sessionId: id,
      startedAt: now,
      elapsed: Duration.zero,
      running: true,
    );
    _tick = Stream.periodic(const Duration(seconds: 1), (_) => _stopwatch!.elapsed)
        .listen((e) {
      if (mounted) state = state.copyWith(elapsed: e);
    });
  }

  /// 结束专注。守卫：非 running 态直接 return（处理通知栏+app 内竞态）。
  Future<void> stop() async {
    if (!state.running) return;
    _tick?.cancel();
    _tick = null;
    _stopwatch?.stop();
    final elapsed = _stopwatch?.elapsed ?? Duration.zero;
    _stopwatch = null;

    final sessionId = state.sessionId;
    if (sessionId != null) {
      final db = await _ref.read(databaseProvider.future);
      final repo = FocusSessionRepository(db);
      await repo.end(sessionId, DateTime.now(), elapsed.inMilliseconds);
    }

    final bridge = _ref.read(focusTimerBridgeProvider);
    try {
      await bridge.stop();
    } catch (_) {
      // 通知栏取消失败不阻断
    }

    state = FocusSessionState.idle;
  }

  /// 启动时调用：恢复或清理孤儿会话。
  /// - 原生仍在跑 + DB 有未结束会话 → 恢复 running（Stopwatch 从 startedAt 重算）
  /// - 原生未跑 + DB 有未结束会话 → 视为崩溃残留，补结束
  Future<void> recoverOrphan() async {
    if (state.running) return;
    final db = await _ref.read(databaseProvider.future);
    final repo = FocusSessionRepository(db);
    final open = await repo.findOpenSession();
    if (open == null) return;

    final bridge = _ref.read(focusTimerBridgeProvider);
    final nativeRunning = await bridge.isRunning();

    if (nativeRunning) {
      // 恢复：从 startedAt 重算 elapsed
      _stopwatch = Stopwatch()..start();
      // Stopwatch 无法设初始值，用 startedAt 差值在 tick 里算
      final offset = DateTime.now().difference(open.startedAt);
      state = FocusSessionState(
        sessionId: open.id,
        startedAt: open.startedAt,
        elapsed: offset,
        running: true,
      );
      _tick = Stream.periodic(const Duration(seconds: 1), (_) {
        // elapsed = 初始 offset + stopwatch 增量
        return offset + (_stopwatch?.elapsed ?? Duration.zero);
      }).listen((e) {
        if (mounted) state = state.copyWith(elapsed: e);
      });
    } else {
      // 清理：补结束
      final elapsed = DateTime.now().difference(open.startedAt);
      await repo.end(open.id!, DateTime.now(), elapsed.inMilliseconds);
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }
}

final focusSessionProvider =
    StateNotifierProvider<FocusSessionNotifier, FocusSessionState>((ref) {
  return FocusSessionNotifier(ref);
});
