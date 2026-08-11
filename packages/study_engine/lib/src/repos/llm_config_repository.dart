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

  /// 按主键更新业务字段(不含 id 与 created_at)。
  /// [c.id] 必须非空,否则抛 [ArgumentError]。
  Future<void> update(LlmConfig c) async {
    if (c.id == null) {
      throw ArgumentError('LlmConfigRepository.update 需要非空 id');
    }
    await _db.db.rawUpdate(
      'UPDATE llm_config SET name = ?, api_url = ?, api_key = ?, model = ?, '
      'supports_vision = ?, is_default = ?, sort_order = ? WHERE id = ?',
      [
        c.name,
        c.apiUrl,
        c.apiKey,
        c.model,
        c.supportsVision ? 1 : 0,
        c.isDefault ? 1 : 0,
        c.sortOrder,
        c.id,
      ],
    );
  }
}
