import 'package:sqflite_common/sqlite_api.dart';

import '../db/database.dart';

/// prompt_override 表仓储：system prompt 的运行时覆盖。
///
/// scenario_id 为主键；get 返回 null 表示该场景无覆盖（走引擎默认模板）。
/// App 层 DbPromptResolver 用 get 实现「有覆盖用覆盖、无则默认」。
class PromptOverrideRepository {
  final StudyDatabase _db;
  PromptOverrideRepository(this._db);

  /// 读取某场景的覆盖 prompt；无覆盖返回 null。
  Future<String?> get(String scenarioId) async {
    final rows = await _db.db.query(
      'prompt_override',
      where: 'scenario_id = ?',
      whereArgs: [scenarioId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['content'] as String?;
  }

  /// 写入/更新覆盖（存在则覆盖 content 与 updated_at）。
  Future<void> upsert(String scenarioId, String content) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await _db.db.insert(
      'prompt_override',
      {'scenario_id': scenarioId, 'content': content, 'updated_at': now},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 删除覆盖（删除后回落到引擎默认模板）。
  Future<void> delete(String scenarioId) async {
    await _db.db.delete(
      'prompt_override',
      where: 'scenario_id = ?',
      whereArgs: [scenarioId],
    );
  }
}
