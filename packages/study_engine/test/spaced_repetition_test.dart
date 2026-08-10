import 'package:test/test.dart';
import 'package:study_engine/study_engine.dart';

void main() {
  final now = DateTime(2026, 8, 10, 12, 0);

  ReviewSchedule sched({
    double ease = 2.5,
    int interval = 0,
    DateTime? next,
    int count = 0,
  }) =>
      ReviewSchedule(
        topicId: 1,
        easeFactor: ease,
        intervalDays: interval,
        nextReviewAt: next ?? now,
        reviewCount: count,
        lastReviewedAt: null,
      );

  test('首学三档：记得→1天，轻松→2天，忘了→1天', () {
    final remembered = SpacedRepetitionService.apply(sched(), ReviewFeedback.remembered, now);
    expect(remembered.intervalDays, 1);
    expect(remembered.nextReviewAt, now.add(const Duration(days: 1)));
    expect(remembered.easeFactor, 2.5); // 记得不改 ease
    expect(remembered.reviewCount, 1);
    expect(remembered.lastReviewedAt, now);

    final easy = SpacedRepetitionService.apply(sched(), ReviewFeedback.easy, now);
    expect(easy.intervalDays, 2);
    expect(easy.easeFactor, 2.6); // 轻松 +0.1

    final forgot = SpacedRepetitionService.apply(sched(), ReviewFeedback.forgot, now);
    expect(forgot.intervalDays, 1);
    expect(forgot.easeFactor, 2.3); // 忘了 -0.2
  });

  test('非首学乘性增长', () {
    final prev = sched(ease: 2.5, interval: 7, next: now.subtract(const Duration(days: 1)));
    final r = SpacedRepetitionService.apply(prev, ReviewFeedback.remembered, now);
    expect(r.intervalDays, (7 * 2.5).round()); // 18
    expect(r.easeFactor, 2.5);

    final e = SpacedRepetitionService.apply(prev, ReviewFeedback.easy, now);
    expect(e.intervalDays, (7 * 2.5 * 1.3).round()); // 23
    expect(e.easeFactor, 2.6);
  });

  test('忘了重置为 1 天', () {
    final prev = sched(ease: 2.5, interval: 30, next: now.subtract(const Duration(days: 3)));
    final f = SpacedRepetitionService.apply(prev, ReviewFeedback.forgot, now);
    expect(f.intervalDays, 1);
    expect(f.easeFactor, 2.3);
  });

  test('ease 上下限 clamp', () {
    var s = sched(ease: 1.3, interval: 1);
    for (var i = 0; i < 10; i++) {
      s = SpacedRepetitionService.apply(s, ReviewFeedback.forgot, now);
    }
    expect(s.easeFactor, 1.3); // 下限不破

    s = sched(ease: 3.0, interval: 1);
    for (var i = 0; i < 10; i++) {
      s = SpacedRepetitionService.apply(s, ReviewFeedback.easy, now);
    }
    expect(s.easeFactor, 3.0); // 上限不破
  });

  test('interval 下限 1 天（round 得 0 兜底）', () {
    final prev = sched(ease: 1.3, interval: 1);
    final r = SpacedRepetitionService.apply(prev, ReviewFeedback.remembered, now);
    expect(r.intervalDays, 1); // 1*1.3=1.3 → round 1
    final e = SpacedRepetitionService.apply(prev, ReviewFeedback.easy, now);
    expect(e.intervalDays, (1 * 1.3 * 1.3).round()); // 2
  });
}
