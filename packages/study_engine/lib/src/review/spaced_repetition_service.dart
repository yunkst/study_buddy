import '../models/models.dart';

/// 间隔重复调度器（简化 SM-2）。纯函数，无 DB 依赖，可单测。
class SpacedRepetitionService {
  static const double kInitialEase = 2.5;
  static const double kMinEase = 1.3;
  static const double kMaxEase = 3.0;

  /// 首学记录（interval 0 → 首次反馈后落地）。
  static ReviewSchedule initial(int topicId, DateTime now) => ReviewSchedule(
        topicId: topicId,
        easeFactor: kInitialEase,
        intervalDays: 0,
        nextReviewAt: now, // 立即可背
        reviewCount: 0,
        lastReviewedAt: null,
      );

  /// 应用反馈，返回新 schedule。now 由调用方传入（测试可固定时间）。
  static ReviewSchedule apply(
      ReviewSchedule prev, ReviewFeedback feedback, DateTime now) {
    double ease = prev.easeFactor;
    int interval;
    switch (feedback) {
      case ReviewFeedback.forgot:
        ease = (ease - 0.2).clamp(kMinEase, kMaxEase).toDouble();
        interval = 1;
        break;
      case ReviewFeedback.remembered:
        ease = ease.clamp(kMinEase, kMaxEase).toDouble();
        interval = prev.intervalDays == 0
            ? 1
            : (prev.intervalDays * ease).round();
        break;
      case ReviewFeedback.easy:
        interval = prev.intervalDays == 0
            ? 2
            : (prev.intervalDays * ease * 1.3).round();
        ease = (ease + 0.1).clamp(kMinEase, kMaxEase).toDouble();
        break;
    }
    if (interval < 1) interval = 1;
    return ReviewSchedule(
      topicId: prev.topicId,
      easeFactor: ease,
      intervalDays: interval,
      nextReviewAt: now.add(Duration(days: interval)),
      reviewCount: prev.reviewCount + 1,
      lastReviewedAt: now,
    );
  }
}
