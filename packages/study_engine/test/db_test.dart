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
      'category', 'topic', 'topic_edge', 'mastery_log',
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

  group('v3 专注时钟', () {
    late StudyDatabase sdb;
    setUpAll(sqfliteFfiInit);
    setUp(() async {
      sdb = await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    });
    tearDown(() async => await sdb.close());

    test('建库后版本为 3', () async {
      expect(await sdb.db.getVersion(), 3);
    });

    test('focus_session 表存在且列结构正确', () async {
      final rows = await sdb.db.rawQuery('PRAGMA table_info(focus_session)');
      final cols = {for (final r in rows) r['name'] as String};
      expect(cols, containsAll(['id', 'started_at', 'ended_at', 'duration_ms']));
    });

    test('focus_session_topic 表存在且列结构正确', () async {
      final rows = await sdb.db.rawQuery('PRAGMA table_info(focus_session_topic)');
      final cols = {for (final r in rows) r['name'] as String};
      expect(cols, containsAll(['id', 'session_id', 'topic_id', 'linked_at']));
    });

    test('focus_session_topic 有 UNIQUE(session_id, topic_id)', () async {
      // 先建一个 category + topic 满足外键
      await sdb.db.insert('category', {'name': '数学', 'sort_order': 0, 'created_at': 0});
      final catId = (await sdb.db.query('category', limit: 1)).first['id'];
      await sdb.db.insert('topic', {
        'category_id': catId, 'question': 'q', 'title': 't1',
        'summary': 's', 'created_at': 0, 'updated_at': 0,
      });
      final topicId = (await sdb.db.query('topic', limit: 1)).first['id'];
      await sdb.db.insert('focus_session', {'started_at': 0});
      final sessionId = (await sdb.db.query('focus_session', limit: 1)).first['id'];

      await sdb.db.insert('focus_session_topic',
          {'session_id': sessionId, 'topic_id': topicId, 'linked_at': 0});
      // 重复插入应抛 UNIQUE
      expect(
        () => sdb.db.insert('focus_session_topic',
            {'session_id': sessionId, 'topic_id': topicId, 'linked_at': 1}),
        throwsA(predicate((e) => e.toString().contains('UNIQUE constraint failed'))),
      );
    });

    test('从 v2 升级到 v3 不丢失现有数据', () async {
      // 关闭刚才的 v3 库，手动建一个 v2 库再升级
      await sdb.close();
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
          options: OpenDatabaseOptions(
            version: 2,
            onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON'),
            onCreate: (d, _) => migrateDatabase(d, 0, 2),
          ));
      // v2 库写一条 topic
      await db.insert('category', {'name': '物理', 'sort_order': 0, 'created_at': 0});
      final catId = (await db.query('category', limit: 1)).first['id'];
      await db.insert('topic', {
        'category_id': catId, 'question': 'q', 'title': '牛顿定律',
        'summary': 's', 'created_at': 0, 'updated_at': 0,
      });
      // 升级到 v3
      await migrateDatabase(db, 2, 3);
      // 旧数据还在
      final topics = await db.query('topic');
      expect(topics, hasLength(1));
      expect(topics.first['title'], '牛顿定律');
      // 新表可用
      await db.insert('focus_session', {'started_at': 0});
      expect((await db.query('focus_session')), hasLength(1));
      await db.close();
    });
  });
}
