import '../db/database.dart';
import '../models/models.dart';

class SubjectRepository {
  final StudyDatabase _db;
  SubjectRepository(this._db);

  /// 按名查找；不存在返回 null。
  Future<Subject?> findByName(String name) async {
    final rows = await _db.db.query('subject', where: 'name = ?', whereArgs: [name], limit: 1);
    return rows.isEmpty ? null : Subject.fromMap(rows.first);
  }

  /// 若不存在则创建，返回该学科。用于 save_topic 按需建学科。
  Future<Subject> ensureCreate(String name) async {
    final existing = await findByName(name);
    if (existing != null) return existing;
    final s = Subject(name: name, createdAt: DateTime.now());
    final id = await _db.db.insert('subject', s.toMap());
    return Subject(id: id, name: name, createdAt: s.createdAt);
  }

  Future<List<Subject>> all() async {
    final rows = await _db.db.query('subject', orderBy: 'name');
    return rows.map(Subject.fromMap).toList();
  }
}
