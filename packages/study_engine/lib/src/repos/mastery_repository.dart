import '../db/database.dart';
import '../models/models.dart';

class MasteryRepository {
  final StudyDatabase _db;
  MasteryRepository(this._db);

  /// 记录一条状态变更。
  Future<int> log(int topicId, MasteryStatus status, {String? reason}) {
    return _db.db.insert('mastery_log', MasteryLog(
      topicId: topicId,
      status: status,
      reason: reason,
      changedAt: DateTime.now(),
    ).toMap());
  }

  /// 当前状态 = 最近一条 log。无记录返回 unknown。
  Future<MasteryStatus> currentStatus(int topicId) async {
    final rows = await _db.db.query(
      'mastery_log',
      where: 'topic_id = ?',
      whereArgs: [topicId],
      orderBy: 'changed_at DESC',
      limit: 1,
    );
    if (rows.isEmpty) return MasteryStatus.unknown;
    return MasteryLog.fromMap(rows.first).status;
  }

  /// 完整时间线，用于遗忘曲线。
  Future<List<MasteryLog>> timeline(int topicId) async {
    final rows = await _db.db.query(
      'mastery_log',
      where: 'topic_id = ?',
      whereArgs: [topicId],
      orderBy: 'changed_at ASC',
    );
    return rows.map(MasteryLog.fromMap).toList();
  }
}
