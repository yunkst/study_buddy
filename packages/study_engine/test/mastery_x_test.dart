import 'package:test/test.dart';
import 'package:study_engine/study_engine.dart';

/// 构造一个已学习的调度（reps>0，lastReviewedAt 非 null 兜底），用于走
/// S 阈值分支而非 unknown 分支。
TopicSchedule _learned(int id, double stability) => TopicSchedule(
      topicId: id,
      stability: stability,
      difficulty: 5.0,
      reps: 1,
      lapses: 0,
      lastReviewedAt: DateTime.utc(2026, 8, 12, 10),
    );

void main() {
  group('MasteryFromSchedule.fromSchedule', () {
    test('null → unknown', () {
      expect(MasteryFromSchedule.fromSchedule(null), MasteryStatus.unknown);
    });

    test('reps==0 且 lastReviewedAt==null → unknown（从未复习）', () {
      final s = TopicSchedule(
        topicId: 1,
        stability: 0,
        difficulty: 5.0,
        reps: 0,
        lapses: 0,
      );
      expect(MasteryFromSchedule.fromSchedule(s), MasteryStatus.unknown);
    });

    test('S=0.5 → weak（低于 kWeakStabilityThreshold=1.0）', () {
      expect(
        MasteryFromSchedule.fromSchedule(_learned(2, 0.5)),
        MasteryStatus.weak,
      );
    });

    test('S=20.99 → learning（低于 kMasteredStabilityThreshold=21.0）', () {
      expect(
        MasteryFromSchedule.fromSchedule(_learned(3, 20.99)),
        MasteryStatus.learning,
      );
    });

    test('S=21.0 → mastered（>= kMasteredStabilityThreshold=21.0）', () {
      expect(
        MasteryFromSchedule.fromSchedule(_learned(4, 21.0)),
        MasteryStatus.mastered,
      );
    });

    test('S=1.0 → learning（边界：不小于 weak 阈值 1.0）', () {
      expect(
        MasteryFromSchedule.fromSchedule(_learned(5, 1.0)),
        MasteryStatus.learning,
      );
    });
  });
}
