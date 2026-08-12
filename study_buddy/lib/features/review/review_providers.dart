/// FSRS 复习模块：今日队列、会话进度状态、评分动作。
/// Task 6.1：封装 Phase 6 复习流的 Riverpod 入口；不依赖 UI 层。
library;

// Riverpod 3 默认不再导出 StateNotifier/StateNotifierProvider,
// 走 legacy.dart 兼容入口以匹配 brief 的 StateNotifier 语义。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:study_engine/study_engine.dart';

import '../../core/providers/topic_schedule_provider.dart';

/// 今日复习队列：dueNow 取前 kDailyReviewCap(20) 张。
final reviewQueueProvider = FutureProvider<List<TopicSchedule>>((ref) async {
  final repo = await ref.watch(topicScheduleRepositoryProvider.future);
  return repo.dueNow(DateTime.now()); // limit 默认 20
});

/// 复习会话进度。
class ReviewSessionState {
  final int index;
  final bool done;

  const ReviewSessionState({this.index = 0, this.done = false});

  ReviewSessionState copyWith({int? index, bool? done}) => ReviewSessionState(
        index: index ?? this.index,
        done: done ?? this.done,
      );
}

/// 复习会话控制器：next(index+1, 越界则 done=true),reset 回到首张。
class ReviewSessionNotifier extends StateNotifier<ReviewSessionState> {
  ReviewSessionNotifier() : super(const ReviewSessionState());

  /// 推进到下一张：越界 → done:true（index 停在最后一张）。
  void next(int total) {
    if (total <= 0) {
      state = state.copyWith(done: true);
      return;
    }
    final i = state.index + 1;
    state = i >= total ? state.copyWith(done: true) : state.copyWith(index: i);
  }

  void reset() => state = const ReviewSessionState();
}

final reviewSessionProvider =
    StateNotifierProvider<ReviewSessionNotifier, ReviewSessionState>(
  (ref) => ReviewSessionNotifier(),
);

/// 评分动作（含新卡上限执行）：
/// 1. 若 schedule.reps == 0（新卡首评）→ 先查 repo.firstGradeCountToday(now)；
///    若 >= kDailyNewCardCap(5) → 该卡顺延：due=明天、reps 不变、不调 grade，
///    直接返回 false 表示"额度用尽"。
/// 2. 否则 ReviewScheduler.grade → repo.upsert → 返回 true。
Future<bool> gradeAndUpsert(
  Ref ref, {
  required TopicSchedule schedule,
  required Rating rating,
  required DateTime now,
}) async {
  final repo = await ref.read(topicScheduleRepositoryProvider.future);
  if (schedule.reps == 0) {
    final gradedToday = await repo.firstGradeCountToday(now);
    if (gradedToday >= kDailyNewCardCap) {
      // 新卡额度用尽：顺延到明天（reps 不变、不调 grade），保持原 S/D。
      final tomorrow = DateTime(now.year, now.month, now.day + 1);
      await repo.upsert(schedule.copyWith(dueAt: tomorrow));
      return false;
    }
  }
  final updated = ReviewScheduler.grade(
    schedule: schedule,
    rating: rating,
    now: now,
  );
  await repo.upsert(updated);
  return true;
}