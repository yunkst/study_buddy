/// FSRS 评分调度器（spec §7.2）。
///
/// 仅暴露纯函数 [ReviewScheduler.grade]：基于当前 [TopicSchedule] 与本次
/// [Rating] 计算下一次调度状态（新稳定性 S、难度 D、累计 reps/lapses、
/// 到期 dueAt、最近评分时间 lastReviewedAt），不改入参，返回全新实例。
///
/// 所有常数引用 [params.dart] 中的 `const`，调参无需触碰算法实现。
library;

import 'dart:math' as math;

import '../models/models.dart';
import 'params.dart';

class ReviewScheduler {
  ReviewScheduler._();

  /// 对 [schedule] 应用一次评分 [rating]，返回新的 [TopicSchedule]。
  ///
  /// 算法分支（spec §7.2）：
  /// - **首次评分（`schedule.reps == 0`）**：
  ///   - Forgot → S=[kInitialSForgot]，due=`now + kForgotInterval`，reps 不变，lapses+=1
  ///   - Hard   → S=[kInitialSHard]，due=`now + 1d`，reps=1
  ///   - Good   → S=[kInitialSGood]，due=`now + 3d`，reps=1
  ///   - Easy   → S=[kInitialSEasy]，due=`now + 8d`，reps=1
  /// - **后续评分（`schedule.reps >= 1`）**：先更新 D（Hard +[kDifficultyHard]、
  ///   Good +0、Easy +[kDifficultyEasy]、Forgot +[kDifficultyForgot]），并夹断到
  ///   `[kMinDifficulty, kMaxDifficulty]`；再：
  ///   - Forgot → S=`max(kMinStabilityAfterLapse, S_old * kLapseStabilityMultiplier)`，
  ///     lapses+=1，reps 不变，due=`now + kForgotInterval`
  ///   - 其它 → S=`S_old * growth * (10-D)/9`（growth 取 [kGrowthHard]/[kGrowthGood]/[kGrowthEasy]），
  ///     reps+=1，interval=`max(1, round(S))` 天，due=`now + interval`
  /// - 每条路径都设 `lastReviewedAt = now`。
  static TopicSchedule grade({
    required TopicSchedule schedule,
    required Rating rating,
    required DateTime now,
  }) {
    if (schedule.reps == 0) {
      return _gradeFirst(schedule: schedule, rating: rating, now: now);
    }
    return _gradeSubsequent(schedule: schedule, rating: rating, now: now);
  }

  /// 首次评分分支。
  static TopicSchedule _gradeFirst({
    required TopicSchedule schedule,
    required Rating rating,
    required DateTime now,
  }) {
    final (stability, dueAt, repsDelta, lapsesDelta) = switch (rating) {
      Rating.forgot => (
          kInitialSForgot,
          now.add(kForgotInterval),
          0,
          1,
        ),
      Rating.hard => (
          kInitialSHard,
          now.add(const Duration(days: 1)),
          1,
          0,
        ),
      Rating.good => (
          kInitialSGood,
          now.add(const Duration(days: 3)),
          1,
          0,
        ),
      Rating.easy => (
          kInitialSEasy,
          now.add(const Duration(days: 8)),
          1,
          0,
        ),
    };
    return schedule.copyWith(
      stability: stability,
      difficulty: schedule.difficulty, // 首次评分不动 D（spec §7.2）
      reps: schedule.reps + repsDelta,
      lapses: schedule.lapses + lapsesDelta,
      dueAt: dueAt,
      lastReviewedAt: now,
    );
  }

  /// 后续评分分支（reps >= 1）。
  static TopicSchedule _gradeSubsequent({
    required TopicSchedule schedule,
    required Rating rating,
    required DateTime now,
  }) {
    // 1) 先更新难度 D（仅本评分反馈，不动 stability）。
    final dDelta = switch (rating) {
      Rating.hard => kDifficultyHard,
      Rating.good => 0.0,
      Rating.easy => kDifficultyEasy,
      Rating.forgot => kDifficultyForgot,
    };
    final rawD = schedule.difficulty + dDelta;
    final newD = rawD.clamp(kMinDifficulty, kMaxDifficulty).toDouble();

    // 2) 按评分分支更新 S / reps / lapses / dueAt。
    switch (rating) {
      case Rating.forgot:
        final newS = math.max<double>(
          kMinStabilityAfterLapse,
          schedule.stability * kLapseStabilityMultiplier,
        );
        return schedule.copyWith(
          stability: newS,
          difficulty: newD,
          // reps 不变
          lapses: schedule.lapses + 1,
          dueAt: now.add(kForgotInterval),
          lastReviewedAt: now,
        );
      case Rating.hard:
      case Rating.good:
      case Rating.easy:
        final growth = switch (rating) {
          Rating.hard => kGrowthHard,
          Rating.good => kGrowthGood,
          Rating.easy => kGrowthEasy,
          Rating.forgot => throw StateError('unreachable'), // 上面已分流
        };
        final newS = schedule.stability * growth * (10 - newD) / 9;
        final intervalDays = math.max(1, newS.round());
        return schedule.copyWith(
          stability: newS,
          difficulty: newD,
          reps: schedule.reps + 1,
          dueAt: now.add(Duration(days: intervalDays)),
          lastReviewedAt: now,
        );
    }
  }
}
