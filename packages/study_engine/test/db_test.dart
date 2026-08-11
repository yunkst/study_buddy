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

  group('v5 专注时钟', () {
    late StudyDatabase sdb;
    setUpAll(sqfliteFfiInit);
    setUp(() async {
      sdb = await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    });
    tearDown(() async => await sdb.close());

    test('建库后版本为 5', () async {
      expect(await sdb.db.getVersion(), 5);
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

    test('从 v4 升级到 v5 不丢失现有数据', () async {
      // 关闭刚才的 v5 库，手动建一个 v4 库再升级
      await sdb.close();
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
          options: OpenDatabaseOptions(
            version: 4,
            onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON'),
            onCreate: (d, _) => migrateDatabase(d, 0, 4),
          ));
      // v4 库写一条 topic
      await db.insert('category', {'name': '物理', 'sort_order': 0, 'created_at': 0});
      final catId = (await db.query('category', limit: 1)).first['id'];
      await db.insert('topic', {
        'category_id': catId, 'question': 'q', 'title': '牛顿定律',
        'summary': 's', 'created_at': 0, 'updated_at': 0,
      });
      // 升级到 v5
      await migrateDatabase(db, 4, 5);
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

  group('mastery_log FK 约束', () {
    late StudyDatabase sdb;
    setUpAll(sqfliteFfiInit);
    setUp(() async {
      sdb = await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    });
    tearDown(() async => await sdb.close());

    test('mastery_log 有指向 topic(id) 的外键', () async {
      // v2 为 DROP topic 临时移除了 mastery_log 的 FK，应在 topic 重建后恢复。
      // foreign_key_list 返回 0 行 = FK 丢失（回归守护）。
      final fks = await sdb.db.rawQuery('PRAGMA foreign_key_list(mastery_log)');
      expect(fks, isNotEmpty, reason: 'mastery_log 应有外键指向 topic');
      final table = fks.any((r) => r['table'] == 'topic');
      expect(table, isTrue, reason: 'mastery_log 外键应指向 topic 表');
    });

    test('插入指向不存在 topic 的 mastery_log 触发 FK 约束', () async {
      // PRAGMA foreign_keys 在 open 的 onConfigure 已开启。
      expect(
        () => sdb.db.insert('mastery_log', {
          'topic_id': 9999, 'status': 'learning', 'changed_at': 0,
        }),
        throwsA(predicate((e) => e.toString().contains('FOREIGN KEY constraint failed'))),
      );
    });
  });

  group('降级处理', () {
    setUpAll(sqfliteFfiInit);

    test('从高版本降级到低版本不崩溃且库可用', () async {
      // 建一个 v5 库并写入数据
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
          options: OpenDatabaseOptions(
            version: 5,
            onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON'),
            onCreate: (d, _) => migrateDatabase(d, 0, 5),
          ));
      await db.insert('category', {'name': 'x', 'sort_order': 0, 'created_at': 0});
      await db.close();

      // 用「降级到 v3」重新打开：onDowngrade 应清空并重建，而非抛异常
      final db2 = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
          options: OpenDatabaseOptions(
            version: 3,
            onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON'),
            onUpgrade: (d, o, n) => migrateDatabase(d, o, n),
            onCreate: (d, _) => migrateDatabase(d, 0, 3),
            onDowngrade: StudyDatabase.onDowngradeRecreate,
          ));
      // 库可用：version=3，旧数据已清空
      expect(await db2.getVersion(), 3);
      expect(await db2.query('category'), isEmpty);
      await db2.close();
    });
  });

  group('migrateDatabase 埋点', () {
    setUpAll(sqfliteFfiInit);

    test('migrateDatabase 通过 sink 上报迁移日志', () async {
      final logger = _RecordingLogger();
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
          options: OpenDatabaseOptions(
            version: kCurrentDbVersion,
            onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON'),
            onCreate: (d, _) =>
                migrateDatabase(d, 0, kCurrentDbVersion, logger: logger),
          ));
      expect(await db.getVersion(), kCurrentDbVersion);
      expect(
        logger.messages.any((m) => m.contains('迁移')),
        isTrue,
        reason: '迁移日志应包含「迁移」关键字,实际 messages=${logger.messages}',
      );
      await db.close();
    });

    // I-2 回归守护:StudyDatabase.open(logger:) 必须把 logger 透传到
    // onCreate/onUpgrade/onDowngrade 三条路径的 migrateDatabase。
    // 此处覆盖 onCreate(新建库)路径——生产 app 首次启动走的就是这条。
    test('StudyDatabase.open(logger:) 透传 logger 到 onCreate 迁移', () async {
      final logger = _RecordingLogger();
      final sdb = await StudyDatabase.open(
        factory: databaseFactoryFfi,
        path: inMemoryDatabasePath,
        logger: logger,
      );
      expect(await sdb.db.getVersion(), kCurrentDbVersion);
      expect(
        logger.messages.any((m) => m.contains('迁移开始')),
        isTrue,
        reason: 'open(logger:) 应透传到 migrateDatabase 的 migration-start 埋点,'
            '实际 messages=${logger.messages}',
      );
      expect(
        logger.messages.any((m) => m.contains('迁移完成')),
        isTrue,
        reason: '迁移完成后应上报 migration-done,实际 messages=${logger.messages}',
      );
      await sdb.close();
    });

    // 向后兼容:不传 logger 时行为不变(NullLoggerSink 兜底),不抛异常。
    test('StudyDatabase.open 不传 logger 时向后兼容', () async {
      final sdb = await StudyDatabase.open(
        factory: databaseFactoryFfi,
        path: inMemoryDatabasePath,
      );
      expect(await sdb.db.getVersion(), kCurrentDbVersion);
      await sdb.close();
    });
  });
}

class _RecordingLogger implements LoggerSink {
  final List<String> messages = [];

  @override
  void log(
    LoggerLevel level,
    String message, {
    String category = 'general',
    String? traceId,
    String? stackTrace,
    List<String> tags = const [],
  }) {
    messages.add(message);
  }
}
