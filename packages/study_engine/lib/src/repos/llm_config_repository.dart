import '../db/database.dart';
import '../models/models.dart';

class LlmConfigRepository {
  final StudyDatabase _db;
  LlmConfigRepository(this._db);

  Future<int> insert(LlmConfig c) => _db.db.insert('llm_config', c.toMap());

  Future<List<LlmConfig>> all() async {
    final rows = await _db.db.query('llm_config', orderBy: 'sort_order');
    return rows.map(LlmConfig.fromMap).toList();
  }

  /// 默认配置。vision=true 时优先返回 supports_vision 的默认项。
  Future<LlmConfig?> getDefault({bool vision = false}) async {
    if (vision) {
      final rows = await _db.db.query(
        'llm_config',
        where: 'is_default = 1 AND supports_vision = 1',
        whereArgs: [],
        orderBy: 'sort_order',
        limit: 1,
      );
      if (rows.isNotEmpty) return LlmConfig.fromMap(rows.first);
    }
    final rows = await _db.db.query('llm_config', where: 'is_default = 1', orderBy: 'sort_order', limit: 1);
    return rows.isEmpty ? null : LlmConfig.fromMap(rows.first);
  }
}
