import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:study_engine/study_engine.dart';

import 'database_provider.dart';
import 'topic_schedule_provider.dart';

/// 分享卡用到的全部「今日学习」数据，一次性聚合。
///
/// 字段来源：
/// - [streak]：连续打卡天数（focus_session 维度，见 study_stats.computeStreak）
/// - [focusMinutes]：今日总专注分钟（DailyReport.totalDurationMs 折算）
/// - [topics]：今日学过的知识点（DailyReport.uniqueTopics，完整 Topic，供 AI 与卡片取 title）
/// - [dueNow]：今日待复习数（复用 dueNowCountProvider）
/// - [totalFocusMinutes]：累计专注分钟（study_stats.totalFocusMinutes）
///
/// 不含 AI 生成的「今日收获」——那由 [dailySummaryProvider] 单独异步生成，
/// 避免数据 provider 被 LLM 慢请求/失败拖垮。
@immutable
class ShareCardData {
  final int streak;
  final int focusMinutes;
  final List<Topic> topics;
  final int dueNow;
  final int totalFocusMinutes;

  const ShareCardData({
    required this.streak,
    required this.focusMinutes,
    required this.topics,
    required this.dueNow,
    required this.totalFocusMinutes,
  });

  /// 今日学过的知识点标题（去重保序，来自 uniqueTopics，无空标题）。
  List<String> get topicTitles =>
      topics.map((t) => t.title).where((s) => s.trim().isNotEmpty).toList(growable: false);
}

/// 今日学习数据聚合（供分享卡渲染）。
///
/// 依赖 [databaseProvider] 与 [dueNowCountProvider]，全量只读，失败由 FutureProvider
/// 自然冒泡（卡片页显示 error 态）。
final shareCardDataProvider = FutureProvider<ShareCardData>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  final focusRepo = FocusSessionRepository(db);
  final topicRepo = TopicRepository(db);
  final now = DateTime.now();

  final report = await buildDailyReport(focusRepo: focusRepo, topicRepo: topicRepo, date: now);
  final streak = await computeStreak(repo: focusRepo, today: now);
  final totalMin = await totalFocusMinutes(repo: focusRepo);
  // 复用 dueNowCountProvider（它已做 kDailyReviewCap + kDailyNewCardCap 上限计算）。
  final dueNow = await ref.watch(dueNowCountProvider.future);

  return ShareCardData(
    streak: streak,
    focusMinutes: report.totalDurationMs ~/ 60000,
    topics: report.uniqueTopics,
    dueNow: dueNow,
    totalFocusMinutes: totalMin,
  );
});
