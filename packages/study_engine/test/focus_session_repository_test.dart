import 'dart:io' show Directory;

import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';
import 'package:study_engine/study_engine.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  late StudyDatabase sdb;
  late FocusSessionRepository repo;
  late int topicId;

  setUp(() async {
    sdb = await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    repo = FocusSessionRepository(sdb);
    // 建一个 topic 供关联
    await sdb.db.insert('category', {'name': '数学', 'sort_order': 0, 'created_at': 0});
    final catId = (await sdb.db.query('category', limit: 1)).first['id'] as int;
    await sdb.db.insert('topic', {
      'category_id': catId, 'question': 'q', 'title': '极限',
      'summary': 's', 'created_at': 0, 'updated_at': 0,
    });
    topicId = (await sdb.db.query('topic', limit: 1)).first['id'] as int;
  });
  tearDown(() async => await sdb.close());

  test('start 插入会话并返回 id，endedAt/duration 为 null', () async {
    final id = await repo.start(DateTime(2026, 8, 10, 9, 0, 0));
    expect(id, greaterThan(0));
    final rows = await sdb.db.query('focus_session');
    expect(rows, hasLength(1));
    expect(rows.first['ended_at'], isNull);
    expect(rows.first['duration_ms'], isNull);
  });

  test('end 写入 ended_at 与 duration_ms', () async {
    final id = await repo.start(DateTime(2026, 8, 10, 9, 0, 0));
    await repo.end(id, DateTime(2026, 8, 10, 9, 30, 0), 1800000);
    final rows = await sdb.db.query('focus_session', where: 'id = ?', whereArgs: [id]);
    expect(rows.first['ended_at'], DateTime(2026, 8, 10, 9, 30, 0).millisecondsSinceEpoch);
    expect(rows.first['duration_ms'], 1800000);
  });

  test('linkTopic 关联知识点', () async {
    final id = await repo.start(DateTime(2026, 8, 10, 9, 0, 0));
    await repo.linkTopic(id, topicId);
    expect(await repo.topicIdsOf(id), [topicId]);
  });

  test('linkTopic 重复关联幂等（不抛错）', () async {
    final id = await repo.start(DateTime(2026, 8, 10, 9, 0, 0));
    await repo.linkTopic(id, topicId);
    await repo.linkTopic(id, topicId); // 不应抛
    expect(await repo.topicIdsOf(id), [topicId]); // 仍只一条
  });

  test('topicIdsOf 按 linked_at 升序', () async {
    // 建第二个 topic
    await sdb.db.insert('topic', {
      'category_id': (await sdb.db.query('category', limit: 1)).first['id'],
      'question': 'q2', 'title': '导数', 'summary': 's', 'created_at': 0, 'updated_at': 0,
    });
    final topicId2 = (await sdb.db.query('topic', where: 'title = ?', whereArgs: ['导数']))
        .first['id'] as int;
    final id = await repo.start(DateTime(2026, 8, 10, 9, 0, 0));
    await repo.linkTopic(id, topicId2); // 先关联导数
    await repo.linkTopic(id, topicId);  // 再关联极限
    expect(await repo.topicIdsOf(id), [topicId2, topicId]); // 按时间
  });

  test('findByDate 只返回当日起止区间内的会话（按 started_at 升序）', () async {
    // 前一天 23:30 开始
    await repo.start(DateTime(2026, 8, 9, 23, 30));
    // 当天 9:00 与 14:00
    final id1 = await repo.start(DateTime(2026, 8, 10, 9, 0));
    final id2 = await repo.start(DateTime(2026, 8, 10, 14, 0));
    // 次日 00:30
    await repo.start(DateTime(2026, 8, 11, 0, 30));

    final result = await repo.findByDate(DateTime(2026, 8, 10));
    expect(result.map((s) => s.id), [id1, id2]);
  });

  test('findOpenSession 返回未结束会话，无则 null', () async {
    expect(await repo.findOpenSession(), isNull);
    final id = await repo.start(DateTime(2026, 8, 10, 9, 0));
    final open = await repo.findOpenSession();
    expect(open?.id, id);
    await repo.end(id, DateTime(2026, 8, 10, 9, 30), 1800000);
    expect(await repo.findOpenSession(), isNull);
  });

  group('setSummary', () {
    test('写入 summary 字段', () async {
      final id = await repo.start(DateTime(2026, 8, 10, 9, 0));
      await repo.setSummary(id, '复习了洛必达法则');
      final rows = await sdb.db.query('focus_session', where: 'id = ?', whereArgs: [id]);
      expect(rows.first['summary'], '复习了洛必达法则');
    });

    test('空串也允许写入（显式清空）', () async {
      final id = await repo.start(DateTime(2026, 8, 10, 9, 0));
      await repo.setSummary(id, '先写点东西');
      await repo.setSummary(id, '');
      final rows = await sdb.db.query('focus_session', where: 'id = ?', whereArgs: [id]);
      expect(rows.first['summary'], '');
    });

    test('不影响其它字段（ended_at/duration_ms 保留）', () async {
      final id = await repo.start(DateTime(2026, 8, 10, 9, 0));
      await repo.end(id, DateTime(2026, 8, 10, 9, 30), 1800000);
      await repo.setSummary(id, '总结');
      final rows = await sdb.db.query('focus_session', where: 'id = ?', whereArgs: [id]);
      expect(rows.first['summary'], '总结');
      expect(rows.first['ended_at'], DateTime(2026, 8, 10, 9, 30).millisecondsSinceEpoch);
      expect(rows.first['duration_ms'], 1800000);
    });

    test('FocusSession.fromMap 读出 summary', () async {
      final id = await repo.start(DateTime(2026, 8, 10, 9, 0));
      await repo.setSummary(id, '高数刷题');
      final rows = await sdb.db.query('focus_session', where: 'id = ?', whereArgs: [id]);
      final session = FocusSession.fromMap(rows.first);
      expect(session.summary, '高数刷题');
    });
  });

  group('v6→v7 迁移', () {
    test('ALTER 加 summary 列且老会话 summary 为 null', () async {
      // 手动建 v6 库，写一条老 focus_session，再升级到 v7。
      // 用临时文件路径而非 :memory:——sqflite FFI 默认单实例内存库会跨 open 复用，
      // 上一个 setSummary 测试建的是 v7 库，复用到此会已含 summary 列导致 ADD COLUMN 报重复。
      final tmp = Directory.systemTemp.createTempSync('focus_v6tov7_');
      final path = p.join(tmp.path, 'db.sqlite');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final db = await databaseFactoryFfi.openDatabase(path,
          options: OpenDatabaseOptions(
            version: 6,
            onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON'),
            onCreate: (d, _) => migrateDatabase(d, 0, 6),
          ));
      await db.insert('focus_session', {'started_at': 0});
      final oldId = (await db.query('focus_session', limit: 1)).first['id'] as int;

      // 升级 v6 → v7
      await migrateDatabase(db, 6, 7);

      // summary 列已存在
      final cols = {
        for (final r in await db.rawQuery('PRAGMA table_info(focus_session)')) r['name'] as String
      };
      expect(cols, contains('summary'), reason: 'v7 应给 focus_session 加 summary 列');
      // 老会话 summary 为 null（未回填）
      final rows = await db.query('focus_session', where: 'id = ?', whereArgs: [oldId]);
      expect(rows.first['summary'], isNull);
      // 升级后可正常写 summary
      await db.update('focus_session', {'summary': '迁移后写入'},
          where: 'id = ?', whereArgs: [oldId]);
      expect(
        (await db.query('focus_session', where: 'id = ?', whereArgs: [oldId]))
            .first['summary'],
        '迁移后写入',
      );
      await db.close();
    });
  });
}
