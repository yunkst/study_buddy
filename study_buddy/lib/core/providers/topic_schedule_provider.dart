import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:study_engine/study_engine.dart';

import 'database_provider.dart';

/// FSRS TopicScheduleRepository（等待 db 就绪）。
final topicScheduleRepositoryProvider = FutureProvider<TopicScheduleRepository>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  return TopicScheduleRepository(db);
});

/// 今日待复习数量（今日 Tab 用）。
final dueNowCountProvider = FutureProvider<int>((ref) async {
  final repo = await ref.watch(topicScheduleRepositoryProvider.future);
  final list = await repo.dueNow(DateTime.now(), limit: kDailyReviewCap + kDailyNewCardCap);
  return list.length;
});
