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

  /// 今日新增队列：topic.created_at >= startOfDay 且尚未建 schedule 的 topic，
  /// 按 created_at 升序。LEFT JOIN 排除已建 schedule 的 topic——背过即移出今日新增，
  /// 避免「再来一轮」对同一卡二次 apply 导致 SM-2 interval 复合跳增。
  Future<List<ReviewQueueItem>> todayNewQueue(DateTime startOfDay) async {
    final rows = await _db.db.rawQuery(
      '''
      SELECT t.id, t.title, t.question
      FROM topic t
      LEFT JOIN review_schedule s ON s.topic_id = t.id
      WHERE t.created_at >= ? AND s.topic_id IS NULL
      ORDER BY t.created_at ASC
      ''',
      [startOfDay.millisecondsSinceEpoch],
    );
    return rows
        .map((r) =>
            ReviewQueueItem(r['id'] as int, r['title'] as String, r['question'] as String))
        .toList();
  }
}
