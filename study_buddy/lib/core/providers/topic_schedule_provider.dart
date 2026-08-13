import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:study_engine/study_engine.dart';

import 'daily_review_limit_provider.dart';
import 'database_provider.dart';

/// FSRS TopicScheduleRepository（等待 db 就绪）。
final topicScheduleRepositoryProvider = FutureProvider<TopicScheduleRepository>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  return TopicScheduleRepository(db);
});

/// 今日待复习数量（今日 Tab 用）。
///
/// limit 取「用户每日复习上限 + 新卡上限」：复习卡与今日到期的新卡都计入今日待复习数。
/// 新卡上限 kDailyNewCardCap 独立于用户配置的复习上限，不并入。
final dueNowCountProvider = FutureProvider<int>((ref) async {
  final repo = await ref.watch(topicScheduleRepositoryProvider.future);
  final reviewLimit = await ref.watch(dailyReviewLimitProvider.future);
  final list = await repo.dueNow(
    DateTime.now(),
    limit: reviewLimit + kDailyNewCardCap,
  );
  return list.length;
});
