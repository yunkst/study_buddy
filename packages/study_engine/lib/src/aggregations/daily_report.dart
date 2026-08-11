import '../models/models.dart';
import '../repos/focus_session_repository.dart';
import '../repos/topic_repository.dart';

/// 日报中一个会话的展示项：会话本身 + 该会话关联的知识点详情。
class DailyReportSession {
  final FocusSession session;
  final List<Topic> topics;
  const DailyReportSession(this.session, this.topics);
}

/// 日报聚合结果。
class DailyReport {
  final DateTime date;
  final List<DailyReportSession> sessions;
  const DailyReport(this.date, this.sessions);

  /// 当天总专注用时（毫秒）。进行中会话（durationMs 为 null）计 0。
  int get totalDurationMs =>
      sessions.fold(0, (sum, s) => sum + (s.session.durationMs ?? 0));

  /// 当天接触的全部知识点（去重，保持首次出现顺序）。
  List<Topic> get uniqueTopics {
    final seen = <int>{};
    final result = <Topic>[];
    for (final s in sessions) {
      for (final t in s.topics) {
        if (t.id != null && seen.add(t.id!)) result.add(t);
      }
    }
    return result;
  }
}

/// 按日期聚合日报。纯函数无副作用：只读 Repository。
///
/// 会话按 [FocusSessionRepository.findByDate] 的 started_at 升序返回；
/// 每个会话关联的知识点按 linked_at 升序，跳过已删除的 topic。
Future<DailyReport> buildDailyReport({
  required FocusSessionRepository focusRepo,
  required TopicRepository topicRepo,
  required DateTime date,
}) async {
  final sessions = await focusRepo.findByDate(date);
  final reportSessions = <DailyReportSession>[];
  for (final s in sessions) {
    final topicIds = await focusRepo.topicIdsOf(s.id!);
    final topics = <Topic>[];
    for (final id in topicIds) {
      final t = await topicRepo.findById(id);
      if (t != null) topics.add(t);
    }
    reportSessions.add(DailyReportSession(s, topics));
  }
  return DailyReport(date, reportSessions);
}
