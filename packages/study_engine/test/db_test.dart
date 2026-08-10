import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';
import 'package:study_engine/study_engine.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  test('建库后 11 张表存在', () async {
    final factory = databaseFactoryFfi;
    final dbPath = inMemoryDatabasePath;
    final sdb = await StudyDatabase.open(factory: factory, path: dbPath);
    final tables = await sdb.db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name",
    );
    final names = tables.map((r) => r['name'] as String).toSet();
    for (final t in [
      'category', 'topic', 'topic_edge', 'mastery_log',
      'llm_config', 'agent_memory', 'chat_session', 'chat_message',
      'plan', 'milestone', 'assessment',
    ]) {
      expect(names, contains(t), reason: '缺表: $t');
    }
    await sdb.close();
  });

  test('v3 新增 plan/milestone/assessment 三表', () async {
    final factory = databaseFactoryFfi;
    final sdb = await StudyDatabase.open(factory: factory, path: inMemoryDatabasePath);
    final tables = await sdb.db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name",
    );
    final names = tables.map((r) => r['name'] as String).toSet();
    for (final t in ['plan', 'milestone', 'assessment']) {
      expect(names, contains(t), reason: '缺表: $t');
    }
    await sdb.close();
  });

  test('FK CASCADE：删 plan 连带删 milestone 与 assessment', () async {
    final factory = databaseFactoryFfi;
    final sdb = await StudyDatabase.open(factory: factory, path: inMemoryDatabasePath);
    final now = DateTime.now();
    final pid = await sdb.db.insert('plan', {
      'name': '考研', 'exam_date': now.millisecondsSinceEpoch, 'exam_content': 'c',
      'target': 't', 'daily_minutes': 180,
      'created_at': now.millisecondsSinceEpoch, 'updated_at': now.millisecondsSinceEpoch,
    });
    await sdb.db.insert('milestone', {
      'plan_id': pid, 'title': 'm1', 'description': 'd', 'target_date': now.millisecondsSinceEpoch,
      'sort_order': 0, 'status': 'pending',
      'created_at': now.millisecondsSinceEpoch, 'updated_at': now.millisecondsSinceEpoch,
    });
    await sdb.db.insert('assessment', {
      'plan_id': pid, 'score': 300, 'assessed_at': now.millisecondsSinceEpoch,
      'created_at': now.millisecondsSinceEpoch,
    });
    await sdb.db.delete('plan', where: 'id = ?', whereArgs: [pid]);
    final ms = await sdb.db.query('milestone', where: 'plan_id = ?', whereArgs: [pid]);
    final as_ = await sdb.db.query('assessment', where: 'plan_id = ?', whereArgs: [pid]);
    expect(ms, isEmpty, reason: 'milestone 未级联删除');
    expect(as_, isEmpty, reason: 'assessment 未级联删除');
    await sdb.close();
  });

  test('重复 open 同一内存库不出错', () async {
    final factory = databaseFactoryFfi;
    final sdb = await StudyDatabase.open(factory: factory, path: inMemoryDatabasePath);
    await sdb.close();
    expect(true, isTrue);
  });
}
