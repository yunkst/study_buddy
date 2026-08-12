import 'dart:math' as math;

import 'package:test/test.dart';
import 'package:study_engine/study_engine.dart';

/// 测试基底：未评分过的空白调度（reps=0, D=5.0）。
TopicSchedule _empty(int id) => TopicSchedule(
      topicId: id,
      stability: 0,
      difficulty: 5.0,
      reps: 0,
      lapses: 0,
    );

void main() {
  // spec §7.2 评分算法的固定参考时间。
  final now = DateTime.utc(2026, 8, 12, 10);

  group('首次评分（reps == 0）', () {
    test('Forgot: S=kInitialSForgot, due=now+30min, reps 不变, lapses+=1', () {
      final s = ReviewScheduler.grade(
        schedule: _empty(1),
        rating: Rating.forgot,
        now: now,
      );
      expect(s.stability, kInitialSForgot);
      expect(s.dueAt, now.add(kForgotInterval));
      expect(s.reps, 0);
      expect(s.lapses, 1);
      expect(s.lastReviewedAt, now);
    });

    test('Hard: S=kInitialSHard, due=now+1d, reps=1, lapses 不变', () {
      final s = ReviewScheduler.grade(
        schedule: _empty(2),
        rating: Rating.hard,
        now: now,
      );
      expect(s.stability, kInitialSHard);
      expect(s.dueAt, now.add(const Duration(days: 1)));
      expect(s.reps, 1);
      expect(s.lapses, 0);
      expect(s.lastReviewedAt, now);
    });

    test('Good: S=kInitialSGood, due=now+3d, reps=1', () {
      final s = ReviewScheduler.grade(
        schedule: _empty(3),
        rating: Rating.good,
        now: now,
      );
      expect(s.stability, kInitialSGood);
      expect(s.dueAt, now.add(const Duration(days: 3)));
      expect(s.reps, 1);
      expect(s.lapses, 0);
      expect(s.lastReviewedAt, now);
    });

    test('Easy: S=kInitialSEasy, due=now+8d, reps=1', () {
      final s = ReviewScheduler.grade(
        schedule: _empty(4),
        rating: Rating.easy,
        now: now,
      );
      expect(s.stability, kInitialSEasy);
      expect(s.dueAt, now.add(const Duration(days: 8)));
      expect(s.reps, 1);
      expect(s.lapses, 0);
      expect(s.lastReviewedAt, now);
    });
  });

  group('后续评分（reps >= 1）', () {
    // 4 个分支的公共前置：已学过一次（S=4, D=5.0, reps=1, lapses=0）。
    TopicSchedule learned(int id) => TopicSchedule(
          topicId: id,
          stability: 4.0,
          difficulty: 5.0,
          reps: 1,
          lapses: 0,
        );

    test('Good: D 不变, S = 4*kGrowthGood*(10-5)/9, reps=2, due=round(S) 天', () {
      final s = ReviewScheduler.grade(
        schedule: learned(10),
        rating: Rating.good,
        now: now,
      );
      final expectedS = 4.0 * kGrowthGood * (10 - 5.0) / 9;
      expect(s.difficulty, 5.0);
      expect(s.stability, closeTo(expectedS, 1e-9));
      expect(s.reps, 2);
      expect(s.lapses, 0);
      // round(50/9) = round(5.555...) = 6 天
      final expectedDays = (expectedS).round();
      expect(expectedDays, 6);
      expect(s.dueAt, now.add(Duration(days: expectedDays)));
      expect(s.lastReviewedAt, now);
    });

    test('Hard: D=5.15, S = 4*kGrowthHard*(10-5.15)/9, reps=2', () {
      final s = ReviewScheduler.grade(
        schedule: learned(11),
        rating: Rating.hard,
        now: now,
      );
      expect(s.difficulty, closeTo(5.15, 1e-9));
      final expectedS = 4.0 * kGrowthHard * (10 - 5.15) / 9;
      expect(s.stability, closeTo(expectedS, 1e-9));
      expect(s.reps, 2);
      expect(s.lapses, 0);
      final expectedDays = math.max(1, expectedS.round());
      expect(s.dueAt, now.add(Duration(days: expectedDays)));
      expect(s.lastReviewedAt, now);
    });

    test('Easy: D=4.85, S = 4*kGrowthEasy*(10-4.85)/9, reps=2', () {
      final s = ReviewScheduler.grade(
        schedule: learned(12),
        rating: Rating.easy,
        now: now,
      );
      expect(s.difficulty, closeTo(4.85, 1e-9));
      final expectedS = 4.0 * kGrowthEasy * (10 - 4.85) / 9;
      expect(s.stability, closeTo(expectedS, 1e-9));
      expect(s.reps, 2);
      expect(s.lapses, 0);
      final expectedDays = math.max(1, expectedS.round());
      expect(s.dueAt, now.add(Duration(days: expectedDays)));
      expect(s.lastReviewedAt, now);
    });

    test('Forgot: S = max(0.4, 10*0.3) = 3.0, lapses+=1, reps 不变, due=+30min', () {
      // 用 S=10 触发非夹断路径(10*0.3=3.0 > 0.4)。
      final pre = TopicSchedule(
        topicId: 13,
        stability: 10.0,
        difficulty: 5.0,
        reps: 3,
        lapses: 2,
      );
      final s = ReviewScheduler.grade(
        schedule: pre,
        rating: Rating.forgot,
        now: now,
      );
      final expectedS = math.max(
        kMinStabilityAfterLapse,
        10.0 * kLapseStabilityMultiplier,
      );
      expect(expectedS, 3.0);
      expect(s.stability, closeTo(3.0, 1e-9));
      expect(s.reps, 3); // reps 不变
      expect(s.lapses, 3); // 2 + 1
      expect(s.dueAt, now.add(kForgotInterval));
      expect(s.lastReviewedAt, now);
    });
  });

  group('难度 D 边界 clamp', () {
    test('Easy 从 D=1.05 夹到 1.0（kMinDifficulty）', () {
      final pre = TopicSchedule(
        topicId: 20,
        stability: 3.0,
        difficulty: 1.05,
        reps: 1,
        lapses: 0,
      );
      final s = ReviewScheduler.grade(
        schedule: pre,
        rating: Rating.easy,
        now: now,
      );
      // 1.05 + (-0.15) = 0.9 → clamp 到 1.0
      expect(s.difficulty, kMinDifficulty);
      expect(s.lastReviewedAt, now);
    });

    test('Forgot 从 D=9.9 夹到 10.0（kMaxDifficulty）', () {
      final pre = TopicSchedule(
        topicId: 21,
        stability: 3.0,
        difficulty: 9.9,
        reps: 1,
        lapses: 0,
      );
      final s = ReviewScheduler.grade(
        schedule: pre,
        rating: Rating.forgot,
        now: now,
      );
      // 9.9 + 0.5 = 10.4 → clamp 到 10.0
      expect(s.difficulty, kMaxDifficulty);
      expect(s.lastReviewedAt, now);
    });
  });

  group('interval 最小 1 天', () {
    test('S=0.1 评 Good: round(0.1*2.5*(10-D)/9) < 1 → due=now+1d', () {
      final pre = TopicSchedule(
        topicId: 30,
        stability: 0.1,
        difficulty: 5.0,
        reps: 1,
        lapses: 0,
      );
      final s = ReviewScheduler.grade(
        schedule: pre,
        rating: Rating.good,
        now: now,
      );
      final rawS = 0.1 * kGrowthGood * (10 - 5.0) / 9;
      // rawS ≈ 0.139 → round = 0 → 钳到 1
      expect(rawS, lessThan(1.0));
      expect(s.dueAt, now.add(const Duration(days: 1)));
      expect(s.lastReviewedAt, now);
    });
  });

  group('每次评分都写 lastReviewedAt', () {
    test('四种评分 × 首次/后续两条路径 lastReviewedAt 均 == now', () {
      for (final rating in Rating.values) {
        final first = ReviewScheduler.grade(
          schedule: _empty(50),
          rating: rating,
          now: now,
        );
        expect(first.lastReviewedAt, now, reason: '$rating 首次路径');

        final subsequent = ReviewScheduler.grade(
          schedule: TopicSchedule(
            topicId: 51,
            stability: 4.0,
            difficulty: 5.0,
            reps: 2,
            lapses: 1,
          ),
          rating: rating,
          now: now,
        );
        expect(subsequent.lastReviewedAt, now, reason: '$rating 后续路径');
      }
    });
  });

  group('不可变性', () {
    test('grade 不修改入参 TopicSchedule（返回新实例）', () {
      final original = _empty(99);
      // 拍照入参字段
      final origStability = original.stability;
      final origReps = original.reps;
      final origLapses = original.lapses;
      final result = ReviewScheduler.grade(
        schedule: original,
        rating: Rating.good,
        now: now,
      );
      expect(identical(result, original), isFalse);
      expect(original.stability, origStability);
      expect(original.reps, origReps);
      expect(original.lapses, origLapses);
      // 入参的 lastReviewedAt/dueAt 仍为 null
      expect(original.lastReviewedAt, isNull);
      expect(original.dueAt, isNull);
    });
  });
}
