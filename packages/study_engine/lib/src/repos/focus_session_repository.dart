import '../db/database.dart';
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
      // 幂等：已关联则忽略
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
}
