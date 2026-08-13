import '../db/database.dart';
import '../logging/logger_sink.dart';
import '../models/models.dart';

/// 专注会话仓储：会话生命周期 + 知识点关联 + 按日期查询。
class FocusSessionRepository {
  final StudyDatabase _db;
  FocusSessionRepository(this._db);

  /// 开始一次会话：插入 started_at，返回新 id。
  Future<int> start(DateTime startedAt) {
    return _db.db.insert('focus_session', FocusSession(startedAt: startedAt).toMap());
  }

  /// 结束会话：写入 ended_at 与 duration_ms。
  Future<void> end(int sessionId, DateTime endedAt, int durationMs) {
    return _db.db.update(
      'focus_session',
      {'ended_at': endedAt.millisecondsSinceEpoch, 'duration_ms': durationMs},
      where: 'id = ?',
      whereArgs: [sessionId],
    );
  }

  /// 写入用户备注（停止专注时弹框收集的「这段时间做了什么」）。
  /// 允许空串以显式清空；调用方应自行 trim 决定是否写入空。
  Future<void> setSummary(int sessionId, String summary) {
    return _db.db.update(
      'focus_session',
      {'summary': summary},
      where: 'id = ?',
      whereArgs: [sessionId],
    );
  }

  /// 关联知识点到会话。UNIQUE(session_id, topic_id) 保证幂等，重复关联被吞。
  Future<void> linkTopic(int sessionId, int topicId) async {
    try {
      await _db.db.insert(
        'focus_session_topic',
        FocusSessionTopic(
          sessionId: sessionId,
          topicId: topicId,
          linkedAt: DateTime.now(),
        ).toMap(),
      );
    } catch (e) {
      if (!e.toString().contains('UNIQUE constraint failed')) rethrow;
      // 幂等：已关联则忽略。记 debug 供排障时确认「重复关联被吞」而非缺失。
      _db.logger.log(LoggerLevel.debug,
          '关联知识点重复被吞: session=$sessionId topic=$topicId',
          category: 'database', tags: const ['idempotent-unique']);
    }
  }

  /// 查某日全部会话（按 started_at 升序）。dateLocal 取本地日期部分，
  /// 区间为 [当日0点, 次日0点)。
  Future<List<FocusSession>> findByDate(DateTime dateLocal) async {
    final start = DateTime(dateLocal.year, dateLocal.month, dateLocal.day)
        .millisecondsSinceEpoch;
    final end = DateTime(dateLocal.year, dateLocal.month, dateLocal.day + 1)
        .millisecondsSinceEpoch;
    final rows = await _db.db.query(
      'focus_session',
      where: 'started_at >= ? AND started_at < ?',
      whereArgs: [start, end],
      orderBy: 'started_at ASC',
    );
    return rows.map(FocusSession.fromMap).toList();
  }

  /// 某会话关联的知识点 id 列表（按 linked_at 升序）。
  Future<List<int>> topicIdsOf(int sessionId) async {
    final rows = await _db.db.query(
      'focus_session_topic',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'linked_at ASC',
    );
    return rows.map((r) => r['topic_id'] as int).toList();
  }

  /// 查未结束的孤儿会话（ended_at IS NULL）。无则 null。
  /// 用于 app 启动时清理崩溃残留（见 FocusSessionNotifier 恢复逻辑）。
  Future<FocusSession?> findOpenSession() async {
    final rows = await _db.db.query(
      'focus_session',
      where: 'ended_at IS NULL',
      orderBy: 'started_at DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : FocusSession.fromMap(rows.first);
  }

  /// 全部有专注记录的本地日期（去重，升序）。
  ///
  /// 用于算"连续打卡天数"（见 study_stats.computeStreak）。`started_at` 存的是
  /// 本地毫秒时间戳，日期提取在 Dart 层做——避免 SQLite `date()` 按 UTC 转换
  /// 在跨时区时出现日期偏差。
  Future<List<DateTime>> activeDays() async {
    final rows = await _db.db.rawQuery(
      'SELECT started_at FROM focus_session ORDER BY started_at ASC',
    );
    final seen = <int, DateTime>{};
    for (final r in rows) {
      final ms = r['started_at'] as int;
      final start = DateTime.fromMillisecondsSinceEpoch(ms);
      final day = DateTime(start.year, start.month, start.day);
      seen.putIfAbsent(day.millisecondsSinceEpoch, () => day);
    }
    final days = seen.values.toList();
    days.sort();
    return days;
  }

  /// 全部已结束专注会话的累计时长（毫秒）。进行中会话（duration_ms 为 null）不计。
  Future<int> sumDurationMs() async {
    final rows = await _db.db.rawQuery(
      'SELECT COALESCE(SUM(duration_ms), 0) AS total FROM focus_session',
    );
    return (rows.first['total'] as int?) ?? 0;
  }
}
