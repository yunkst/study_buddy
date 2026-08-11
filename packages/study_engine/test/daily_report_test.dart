import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';
import 'package:study_engine/study_engine.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  late StudyDatabase sdb;
  late FocusSessionRepository focusRepo;
  late TopicRepository topicRepo;
  late int t1, t2;

  setUp(() async {
    sdb = await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    focusRepo = FocusSessionRepository(sdb);
    topicRepo = TopicRepository(sdb);
    final cats = CategoryRepository(sdb);
    final catId = await cats.ensurePath(['数学']);
    final now = DateTime(2026, 8, 10);
    t1 = await topicRepo.insert(Topic(
      categoryId: catId, question: 'q1', title: '极限', summary: 's1',
      createdAt: now, updatedAt: now,
    ));
    t2 = await topicRepo.insert(Topic(
      categoryId: catId, question: 'q2', title: '导数', summary: 's2',
      createdAt: now, updatedAt: now,
    ));
  });
  tearDown(() async => await sdb.close());

  test('空日报：无会话时 totalDuration 为 0、topics 为空', () async {
    final report = await buildDailyReport(
      focusRepo: focusRepo, topicRepo: topicRepo, date: DateTime(2026, 8, 10));
    expect(report.sessions, isEmpty);
    expect(report.totalDurationMs, 0);
    expect(report.uniqueTopics, isEmpty);
  });

  test('单会话：聚合 duration 与关联知识点', () async {
    final id = await focusRepo.start(DateTime(2026, 8, 10, 9, 0));
    await focusRepo.end(id, DateTime(2026, 8, 10, 9, 30), 1800000);
    await focusRepo.linkTopic(id, t1);

    final report = await buildDailyReport(
      focusRepo: focusRepo, topicRepo: topicRepo, date: DateTime(2026, 8, 10));
    expect(report.sessions, hasLength(1));
    expect(report.totalDurationMs, 1800000);
    expect(report.sessions.first.topics.map((t) => t.title), ['极限']);
    expect(report.uniqueTopics.map((t) => t.title), ['极限']);
  });

  test('多会话：totalDuration 累加、知识点跨会话去重保序', () async {
    final id1 = await focusRepo.start(DateTime(2026, 8, 10, 9, 0));
    await focusRepo.end(id1, DateTime(2026, 8, 10, 9, 30), 1800000);
    await focusRepo.linkTopic(id1, t1);
    await focusRepo.linkTopic(id1, t2);

    final id2 = await focusRepo.start(DateTime(2026, 8, 10, 14, 0));
    await focusRepo.end(id2, DateTime(2026, 8, 10, 15, 0), 3600000);
    await focusRepo.linkTopic(id2, t1); // 重复关联 t1，应去重

    final report = await buildDailyReport(
      focusRepo: focusRepo, topicRepo: topicRepo, date: DateTime(2026, 8, 10));
    expect(report.sessions, hasLength(2));
    expect(report.totalDurationMs, 5400000); // 1800000 + 3600000
    // uniqueTopics 去重，保首次出现顺序：t1, t2
    expect(report.uniqueTopics.map((t) => t.title), ['极限', '导数']);
  });

  test('跨午夜会话归入开始日', () async {
    // 8月10日 23:00 开始，8月11日 01:00 结束
    final id = await focusRepo.start(DateTime(2026, 8, 10, 23, 0));
    await focusRepo.end(id, DateTime(2026, 8, 11, 1, 0), 7200000);
    await focusRepo.linkTopic(id, t1);

    final report10 = await buildDailyReport(
      focusRepo: focusRepo, topicRepo: topicRepo, date: DateTime(2026, 8, 10));
    final report11 = await buildDailyReport(
      focusRepo: focusRepo, topicRepo: topicRepo, date: DateTime(2026, 8, 11));
    expect(report10.sessions, hasLength(1)); // 归入 10 日
    expect(report10.totalDurationMs, 7200000);
    expect(report11.sessions, isEmpty);
  });

  test('会话含已删除知识点：topics 跳过不存在的', () async {
    final id = await focusRepo.start(DateTime(2026, 8, 10, 9, 0));
    await focusRepo.end(id, DateTime(2026, 8, 10, 9, 30), 1800000);
    await focusRepo.linkTopic(id, t1);
    // focus_session_topic.topic_id 有 FK 约束（ON DELETE CASCADE），linkTopic 无法
    // 写入不存在的 topic_id。临时关闭 FK 注入一行"悬挂"关联，模拟已删除知识点残留，
    // 以验证 buildDailyReport 的 findById != null 防御分支。
    await sdb.db.execute('PRAGMA foreign_keys = OFF');
    await sdb.db.rawInsert(
      'INSERT INTO focus_session_topic (session_id, topic_id, linked_at) VALUES (?, ?, ?)',
      [id, 99999, DateTime.now().millisecondsSinceEpoch],
    );
    await sdb.db.execute('PRAGMA foreign_keys = ON');

    final report = await buildDailyReport(
      focusRepo: focusRepo, topicRepo: topicRepo, date: DateTime(2026, 8, 10));
    expect(report.sessions.first.topics, hasLength(1)); // 只剩存在的
    expect(report.sessions.first.topics.first.title, '极限');
  });
}
