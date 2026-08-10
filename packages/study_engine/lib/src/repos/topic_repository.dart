import '../db/database.dart';
import '../models/models.dart';

/// search 的结果：items + 命中总数（用于分页"还有 N 条未展示"）。
class TopicSearchResult {
  final List<TopicSearchItem> items;
  final int total;
  TopicSearchResult(this.items, this.total);
}

/// search 返回的轻量项：仅 id+title+categoryId（调用方再 pathOf 重建路径）。
class TopicSearchItem {
  final int id;
  final String title;
  final int categoryId;
  TopicSearchItem(this.id, this.title, this.categoryId);
}

class TopicRepository {
  final StudyDatabase _db;
  TopicRepository(this._db);

  Future<int> insert(Topic t) => _db.db.insert('topic', t.toMap());

  Future<Topic?> findById(int id) async {
    final rows = await _db.db.query('topic', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : Topic.fromMap(rows.first);
  }

  /// 按 title 精确匹配（全库唯一，save_topic 查重用）。
  Future<Topic?> findByTitle(String title) async {
    final rows = await _db.db.query('topic', where: 'title = ?', whereArgs: [title], limit: 1);
    return rows.isEmpty ? null : Topic.fromMap(rows.first);
  }

  /// 某分类直挂的知识点（仅 id+title，list_topics 用）。
  Future<List<Topic>> findByCategory(int categoryId) async {
    final rows = await _db.db.query('topic', where: 'category_id = ?', whereArgs: [categoryId], orderBy: 'title');
    return rows.map(Topic.fromMap).toList();
  }

  /// 跨 title+question+summary 的 LIKE 搜索。limit 默认 30。
  Future<TopicSearchResult> search(String keyword, {int limit = 30, int offset = 0}) async {
    final like = '%$keyword%';
    final countRows = await _db.db.rawQuery(
      'SELECT COUNT(*) AS c FROM topic WHERE title LIKE ? OR question LIKE ? OR summary LIKE ?',
      [like, like, like],
    );
    final total = countRows.isNotEmpty ? (countRows.first['c'] as int) : 0;
    final rows = await _db.db.rawQuery(
      'SELECT id, title, category_id FROM topic WHERE title LIKE ? OR question LIKE ? OR summary LIKE ? ORDER BY title LIMIT ? OFFSET ?',
      [like, like, like, limit, offset],
    );
    final items = rows.map((r) => TopicSearchItem(r['id'] as int, r['title'] as String, r['category_id'] as int)).toList();
    return TopicSearchResult(items, total);
  }

  /// 更新答案本体并刷新 updated_at。
  Future<void> updateSummary(int id, String summary) async {
    await _db.db.update('topic', {'summary': summary, 'updated_at': DateTime.now().millisecondsSinceEpoch},
        where: 'id = ?', whereArgs: [id]);
  }
}
