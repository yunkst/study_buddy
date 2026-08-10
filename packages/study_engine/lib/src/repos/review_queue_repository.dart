import '../db/database.dart';

/// 可背诵的知识点轻量项。
class ReviewQueueItem {
  final int topicId;
  final String title;
  final String question;
  ReviewQueueItem(this.topicId, this.title, this.question);
}

class ReviewQueueRepository {
  final StudyDatabase _db;
  ReviewQueueRepository(this._db);

  /// 到期复习队列：有 schedule 且 next_review_at <= now，按到期升序。
  /// 一次 JOIN 查询（无 N+1）。
  Future<List<ReviewQueueItem>> dueQueue(DateTime now, {int limit = 200}) async {
    final rows = await _db.db.rawQuery(
      '''
      SELECT t.id, t.title, t.question
      FROM review_schedule s
      JOIN topic t ON t.id = s.topic_id
      WHERE s.next_review_at <= ?
      ORDER BY s.next_review_at ASC
      LIMIT ?
      ''',
      [now.millisecondsSinceEpoch, limit],
    );
    return rows
        .map((r) =>
            ReviewQueueItem(r['id'] as int, r['title'] as String, r['question'] as String))
        .toList();
  }

  /// 今日新增队列：topic.created_at >= startOfDay，按创建升序。
  /// 直接查 topic 表——不依赖 schedule（懒建，今日新增可能尚无调度）。
  Future<List<ReviewQueueItem>> todayNewQueue(DateTime startOfDay) async {
    final rows = await _db.db.rawQuery(
      '''
      SELECT id, title, question
      FROM topic
      WHERE created_at >= ?
      ORDER BY created_at ASC
      ''',
      [startOfDay.millisecondsSinceEpoch],
    );
    return rows
        .map((r) =>
            ReviewQueueItem(r['id'] as int, r['title'] as String, r['question'] as String))
        .toList();
  }
}
