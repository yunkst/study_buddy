import '../models/models.dart';
import 'params.dart';

extension MasteryFromSchedule on MasteryStatus {
  /// 派生展示掌握度：null 或 reps==0 且 lastReviewedAt==null → unknown；
  /// S<1 → weak；1<=S<21 → learning；S>=21 → mastered。
  static MasteryStatus fromSchedule(TopicSchedule? s) {
    if (s == null || (s.reps == 0 && s.lastReviewedAt == null)) {
      return MasteryStatus.unknown;
    }
    if (s.stability < kWeakStabilityThreshold) return MasteryStatus.weak;
    if (s.stability < kMasteredStabilityThreshold) return MasteryStatus.learning;
    return MasteryStatus.mastered;
  }
}
