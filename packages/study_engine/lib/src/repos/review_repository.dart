import 'dart:convert';
import '../db/database.dart';
import '../models/models.dart';

/// 批改记录仓库。items 以 JSON 数组存于 review.items 列。
class ReviewRepository {
  final StudyDatabase _db;
  ReviewRepository(this._db);

  Future<int> save({
    int? chatSessionId,
    required String summary,
    required List<ReviewItem> items,
  }) async {
    final itemsJson = jsonEncode(items.map((i) => i.toJson()).toList());
    return _db.db.insert('review', {
      'chat_session_id': chatSessionId,
      'summary': summary,
      'items': itemsJson,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<Review?> findById(int id) async {
    final rows = await _db.db.query('review', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : Review.fromMap(rows.first);
  }

  Future<List<Review>> findBySession(int chatSessionId) async {
    final rows = await _db.db.query(
      'review',
      where: 'chat_session_id = ?',
      whereArgs: [chatSessionId],
      orderBy: 'created_at DESC',
    );
    return rows.map(Review.fromMap).toList();
  }
}
