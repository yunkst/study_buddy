import '../db/database.dart';
import '../models/models.dart';

class AgentMemoryRepository {
  final StudyDatabase _db;
  AgentMemoryRepository(this._db);

  Future<int> add(String scenarioId, String content) =>
      _db.db.insert('agent_memory', AgentMemory(scenarioId: scenarioId, content: content, createdAt: DateTime.now()).toMap());

  Future<List<AgentMemory>> queryByScenario(String scenarioId) async {
    final rows = await _db.db.query('agent_memory', where: 'scenario_id = ?', whereArgs: [scenarioId], orderBy: 'created_at ASC');
    return rows.map(AgentMemory.fromMap).toList();
  }

  Future<List<AgentMemory>> all() async {
    final rows = await _db.db.query('agent_memory', orderBy: 'created_at ASC');
    return rows.map(AgentMemory.fromMap).toList();
  }

  Future<void> update(int id, String content) =>
      _db.db.update('agent_memory', {'content': content}, where: 'id = ?', whereArgs: [id]);

  Future<void> delete(int id) =>
      _db.db.delete('agent_memory', where: 'id = ?', whereArgs: [id]);
}
