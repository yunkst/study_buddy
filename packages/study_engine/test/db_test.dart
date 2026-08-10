import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';
import 'package:study_engine/study_engine.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  test('建库后 9 张表存在', () async {
    final factory = databaseFactoryFfi;
    final dbPath = inMemoryDatabasePath;
    final sdb = await StudyDatabase.open(factory: factory, path: dbPath);
    final tables = await sdb.db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'",
    );
    expect(tables, hasLength(9));
    final names = tables.map((r) => r['name'] as String).toSet();
    for (final t in [
      'category', 'topic', 'topic_edge', 'mastery_log',
      'llm_config', 'agent_memory', 'chat_session', 'chat_message',
      'review_schedule',
    ]) {
      expect(names, contains(t), reason: '缺表: $t');
    }
    // v4：chat_session 有 topic_id 列
    final cols = await sdb.db.rawQuery('PRAGMA table_info(chat_session)');
    expect(cols.map((c) => c['name']), contains('topic_id'));
    await sdb.close();
  });

  test('重复 open 同一内存库不出错', () async {
    final factory = databaseFactoryFfi;
    final sdb = await StudyDatabase.open(factory: factory, path: inMemoryDatabasePath);
    await sdb.close();
    expect(true, isTrue);
  });
}
