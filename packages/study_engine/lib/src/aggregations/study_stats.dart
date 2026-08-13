import '../repos/focus_session_repository.dart';

/// 连续打卡天数：从 [today] 起向前回溯，统计连续"有专注记录"的天数。
///
/// 定义（与「今日学习」分享卡一致）：某天只要存在任意 focus_session 记录即算打卡。
/// - 若今天打卡，从今天起算；
/// - 若今天还没学，但昨天打了卡，则从昨天起算（允许"今天还没开始"的过渡态）；
/// - 否则 streak = 0。
///
/// 实现说明：[repo.activeDays] 已按本地日期去重升序返回，本函数纯算术回溯，
/// 不碰 SQL，便于单测。
Future<int> computeStreak({
  required FocusSessionRepository repo,
  required DateTime today,
}) async {
  final days = await repo.activeDays();
  if (days.isEmpty) return 0;

  DateTime normalize(DateTime d) => DateTime(d.year, d.month, d.day);
  final todayNorm = normalize(today);

  // 选取回溯起点：今天有记录则从今天起，否则从昨天起（今天还没开始也算连续）。
  final hasToday = days.any((d) => d == todayNorm);
  final cursor = hasToday ? todayNorm : todayNorm.subtract(const Duration(days: 1));

  // 起点本身没记录 → 直接 0（今天没学、昨天也没学）。
  if (!days.contains(cursor)) return 0;

  var streak = 0;
  var probe = cursor;
  final daySet = days.toSet();
  while (daySet.contains(probe)) {
    streak++;
    probe = probe.subtract(const Duration(days: 1));
  }
  return streak;
}

/// 全部专注会话累计时长（分钟，向下取整）。进行中会话不计。
Future<int> totalFocusMinutes({required FocusSessionRepository repo}) async {
  final ms = await repo.sumDurationMs();
  return ms ~/ 60000;
}
