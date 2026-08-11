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
}
