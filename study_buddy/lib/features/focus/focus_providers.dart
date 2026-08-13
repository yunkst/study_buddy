/// 专注时钟页：今日累计统计 + 当前会话关联知识点的聚合 provider。
///
/// 不持有状态、纯只读聚合，供 [FocusPage] 展示「闭环信息」：
/// - idle 态：今日累计专注时长 + 已完成会话次数（激励文案）
/// - running 态：当前会话已关联的知识点 chips（学习反馈）
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:study_engine/study_engine.dart';

import '../../core/providers/database_provider.dart';
import '../../core/providers/focus_session_provider.dart';

/// 今日专注摘要：累计专注毫秒（含进行中会话的实时增量）+ 已结束会话数。
class TodayFocusSummary {
  const TodayFocusSummary({this.totalMs = 0, this.finishedCount = 0});

  /// 今日累计专注毫秒。包含已结束会话的 duration 与进行中会话的实时 elapsed。
  final int totalMs;

  /// 今日已结束的会话数（ended_at 非空）。进行中会话不计入。
  final int finishedCount;

  bool get isEmpty => totalMs == 0 && finishedCount == 0;
}

/// 今日专注摘要。依赖 focusSessionProvider（running 时随每秒 tick 刷新，
/// 故该 provider 也会每秒重算，把进行中会话的实时增量并入今日累计）。
final todayFocusSummaryProvider =
    FutureProvider<TodayFocusSummary>((ref) async {
  // watch focusSessionProvider：running 时每秒变化会触发本 provider 重算
  final sessionState = ref.watch(focusSessionProvider);
  final db = await ref.watch(databaseProvider.future);
  final repo = FocusSessionRepository(db);

  final now = DateTime.now();
  final sessions = await repo.findByDate(now);

  var total = 0;
  var finished = 0;
  for (final s in sessions) {
    if (s.endedAt != null) {
      total += s.durationMs ?? 0;
      finished += 1;
    }
  }
  // 进行中会话的实时增量并入累计（duration_ms 在会话结束后才落库）。
  if (sessionState.running) {
    total += sessionState.elapsed.inMilliseconds;
  }
  return TodayFocusSummary(totalMs: total, finishedCount: finished);
});

/// 当前会话已关联的知识点（按 linked_at 升序）。idle 态返回空列表。
///
/// running 时每秒随 focusSessionProvider 重算（虽 linkTopic 不会每秒变，
/// 但与 summary 同源 watch，刷新时机一致；列表本身去重由 DB UNIQUE 保证）。
final currentSessionTopicsProvider =
    FutureProvider<List<Topic>>((ref) async {
  final sessionState = ref.watch(focusSessionProvider);
  if (!sessionState.running || sessionState.sessionId == null) {
    return const [];
  }
  final db = await ref.watch(databaseProvider.future);
  final repo = FocusSessionRepository(db);
  final topicRepo = TopicRepository(db);

  final ids = await repo.topicIdsOf(sessionState.sessionId!);
  final topics = <Topic>[];
  for (final id in ids) {
    final t = await topicRepo.findById(id);
    if (t != null) topics.add(t);
  }
  return topics;
});
