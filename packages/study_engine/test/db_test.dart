import 'package:sqflite_common/sqlite_api.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';
import 'package:study_engine/study_engine.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  test('建库后 8 张表存在', () async {
    final factory = databaseFactoryFfi;
    final dbPath = inMemoryDatabasePath;
    final sdb = await StudyDatabase.open(factory: factory, path: dbPath);
    final tables = await sdb.db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name",
    );
    final names = tables.map((r) => r['name'] as String).toSet();
    for (final t in [
      'subject', 'topic', 'topic_domain', 'mastery_log',
      'llm_config', 'agent_memory', 'chat_session', 'chat_message',
    ]) {
      expect(names, contains(t), reason: '缺表: $t');
    }
    await sdb.close();
  });

  test('重复 open 同一内存库不出错', () async {
    final factory = databaseFactoryFfi;
    final sdb = await StudyDatabase.open(factory: factory, path: inMemoryDatabasePath);
    await sdb.close();
    expect(true, isTrue);
  });
}
