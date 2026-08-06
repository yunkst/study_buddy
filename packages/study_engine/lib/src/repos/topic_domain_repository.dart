import '../db/database.dart';
import '../models/models.dart';

class TopicDomainRepository {
  final StudyDatabase _db;
  TopicDomainRepository(this._db);

  Future<int> insert(TopicDomain d) => _db.db.insert('topic_domain', d.toMap());

  Future<List<TopicDomain>> queryBySubject(int subjectId) async {
    final rows = await _db.db.query('topic_domain', where: 'subject_id = ?', whereArgs: [subjectId]);
    return rows.map(TopicDomain.fromMap).toList();
  }
}
