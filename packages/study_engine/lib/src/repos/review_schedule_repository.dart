import 'package:sqflite_common/sqlite_api.dart';

import '../db/database.dart';
import '../models/models.dart';

class ReviewScheduleRepository {
  final StudyDatabase _db;
  ReviewScheduleRepository(this._db);

  /// 取调度记录，无则返回 null（懒初始化：null 视为首学）。
  Future<ReviewSchedule?> getByTopic(int topicId) async {
    final rows = await _db.db.query('review_schedule',
        where: 'topic_id = ?', whereArgs: [topicId], limit: 1);
    return rows.isEmpty ? null : ReviewSchedule.fromMap(rows.first);
  }

  /// 插入或更新（topic_id 主键冲突用 REPLACE，原子）。
  Future<void> upsert(ReviewSchedule s) async {
    await _db.db.insert('review_schedule', s.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// 到期记录：next_review_at <= now，升序，限量。
  Future<List<ReviewSchedule>> findDue(DateTime now, {int limit = 200}) async {
    final rows = await _db.db.query(
      'review_schedule',
      where: 'next_review_at <= ?',
      whereArgs: [now.millisecondsSinceEpoch],
      orderBy: 'next_review_at ASC',
      limit: limit,
    );
    return rows.map(ReviewSchedule.fromMap).toList();
  }
}
