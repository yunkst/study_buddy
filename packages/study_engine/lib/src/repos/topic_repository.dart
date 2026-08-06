import '../db/database.dart';
import '../models/models.dart';

class TopicRepository {
  final StudyDatabase _db;
  TopicRepository(this._db);

  Future<int> insert(Topic t) => _db.db.insert('topic', t.toMap());

  Future<Topic?> findById(int id) async {
    final rows = await _db.db.query('topic', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : Topic.fromMap(rows.first);
  }

  /// 按学科查询；domain 非空时按领域过滤。
  Future<List<Topic>> queryBySubject(int subjectId, {String? domain}) async {
    final rows = domain == null
        ? await _db.db.query('topic', where: 'subject_id = ?', whereArgs: [subjectId])
        : await _db.db.query('topic', where: 'subject_id = ? AND domain = ?', whereArgs: [subjectId, domain]);
    return rows.map(Topic.fromMap).toList();
  }

  Future<List<Topic>> queryByParent(int parentId) async {
    final rows = await _db.db.query('topic', where: 'parent_topic_id = ?', whereArgs: [parentId]);
    return rows.map(Topic.fromMap).toList();
  }
}
