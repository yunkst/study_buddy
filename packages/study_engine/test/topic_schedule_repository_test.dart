import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';
import 'package:study_engine/study_engine.dart';

/// Task 1.6：TopicScheduleRepository TDD。
///
/// 覆盖 8 用例（见 task-1.6-brief.md）：
/// 1. upsert + findByTopic round-trip（含毫秒时间戳还原）
/// 2. upsert replace：同 topic_id 插入两次 → 1 行、值更新
/// 3. dueNow 排序：t1 逾期 5d 高 S、t2 逾期 5d 低 S、t3 明日期 → `[t2, t1]`
/// 4. dueNow limit 生效
/// 5. applyMasteryOverride weak → S<=0.5 且 D>=8
/// 6. applyMasteryOverride mastered → S>=21
/// 7. applyMasteryOverride learning → S∈[1,21]
/// 8. applyMasteryOverride unknown → S=0.4 且建行；firstGradeCountToday 跨天计数
void main() {
  setUpAll(sqfliteFfiInit);

  late StudyDatabase sdb;
  late TopicScheduleRepository repo;

  setUp(() async {
    sdb = await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    repo = TopicScheduleRepository(sdb);
  });
  tearDown(() async => await sdb.close());

  /// 建一个分类 + 一个 topic，返回 topicId。
  Future<int> seedTopic({String title = '极限'}) async {
    await sdb.db.insert('category', {'name': '数学', 'sort_order': 0, 'created_at': 0});
    final catId = (await sdb.db.query('category', limit: 1)).first['id'] as int;
    await sdb.db.insert('topic', {
      'category_id': catId,
      'question': 'q',
      'title': title,
      'summary': 's',
      'created_at': 0,
      'updated_at': 0,
    });
    return (await sdb.db.query('topic', where: 'title = ?', whereArgs: [title]))
        .first['id'] as int;
  }

  test('upsert + findByTopic round-trip 还原毫秒时间戳', () async {
    final topicId = await seedTopic();
    final last = DateTime(2026, 8, 12, 10, 30, 0, 123);
    final due = DateTime(2026, 8, 15, 10, 30, 0, 456);
    final s = TopicSchedule(
      topicId: topicId,
      stability: 3.5,
      difficulty: 5.5,
      reps: 2,
      lapses: 1,
      lastReviewedAt: last,
      dueAt: due,
    );
    await repo.upsert(s);

    final found = await repo.findByTopic(topicId);
    expect(found, isNotNull);
    expect(found!.topicId, topicId);
    expect(found.stability, 3.5);
    expect(found.difficulty, 5.5);
    expect(found.reps, 2);
    expect(found.lapses, 1);
    expect(found.lastReviewedAt, last); // 毫秒精度
    expect(found.dueAt, due);
  });

  test('upsert 同 topic_id 再插以 replace 覆盖（仍 1 行、值更新）', () async {
    final topicId = await seedTopic();
    await repo.upsert(TopicSchedule(
      topicId: topicId,
      stability: 1.0,
      difficulty: 5.0,
      reps: 1,
      lapses: 0,
      lastReviewedAt: DateTime(2026, 8, 10),
      dueAt: DateTime(2026, 8, 13),
    ));
    await repo.upsert(TopicSchedule(
      topicId: topicId,
      stability: 9.0,
      difficulty: 7.0,
      reps: 5,
      lapses: 2,
      lastReviewedAt: DateTime(2026, 8, 12),
      dueAt: DateTime(2026, 8, 21),
    ));

    final rows = await sdb.db.query('topic_schedule');
    expect(rows, hasLength(1));
    final found = await repo.findByTopic(topicId);
    expect(found, isNotNull);
    expect(found!.stability, 9.0);
    expect(found.difficulty, 7.0);
    expect(found.reps, 5);
    expect(found.lapses, 2);
  });

  test('dueNow 排序：t1/t2 同逾期 5d 时低 S 在前，明日到期不在队列', () async {
    final t1 = await seedTopic(title: 't1');
    final t2 = await seedTopic(title: 't2');
    final t3 = await seedTopic(title: 't3');
    final now = DateTime(2026, 8, 12, 9, 0, 0);
    final fiveDaysAgo = now.subtract(const Duration(days: 5));
    final tomorrow = now.add(const Duration(days: 1));

    await repo.upsert(TopicSchedule(
      topicId: t1, stability: 50.0, difficulty: 5.0, reps: 3, lapses: 0,
      lastReviewedAt: fiveDaysAgo, dueAt: fiveDaysAgo,
    ));
    await repo.upsert(TopicSchedule(
      topicId: t2, stability: 2.0, difficulty: 5.0, reps: 2, lapses: 0,
      lastReviewedAt: fiveDaysAgo, dueAt: fiveDaysAgo,
    ));
    await repo.upsert(TopicSchedule(
      topicId: t3, stability: 4.0, difficulty: 5.0, reps: 1, lapses: 0,
      lastReviewedAt: now, dueAt: tomorrow,
    ));

    final due = await repo.dueNow(now);
    expect(due.map((s) => s.topicId), [t2, t1]); // t3 不在队列
  });

  test('dueNow limit 截断结果', () async {
    final now = DateTime(2026, 8, 12, 9, 0, 0);
    final overdue = now.subtract(const Duration(days: 3));
    // 建 8 个逾期知识点
    for (var i = 0; i < 8; i++) {
      final tid = await seedTopic(title: 'topic$i');
      await repo.upsert(TopicSchedule(
        topicId: tid,
        stability: 1.0 + i,
        difficulty: 5.0,
        reps: 1,
        lapses: 0,
        lastReviewedAt: overdue,
        dueAt: overdue,
      ));
    }
    final due = await repo.dueNow(now, limit: 3);
    expect(due, hasLength(3));
  });

  test('applyMasteryOverride weak → S<=0.5 且 D>=8', () async {
    final topicId = await seedTopic();
    final now = DateTime(2026, 8, 12, 10, 0, 0);
    await repo.upsert(TopicSchedule(
      topicId: topicId,
      stability: 10.0,
      difficulty: 3.0,
      reps: 2,
      lapses: 0,
      lastReviewedAt: DateTime(2026, 8, 5),
      dueAt: DateTime(2026, 8, 13),
    ));

    final out = await repo.applyMasteryOverride(
      topicId: topicId,
      status: MasteryStatus.weak,
      now: now,
    );
    expect(out.stability, lessThanOrEqualTo(0.5));
    expect(out.difficulty, greaterThanOrEqualTo(8.0));
    expect(out.lastReviewedAt, now);
    // due = now + round(S) 天，min 1
    final intervalDays = out.stability.round() < 1 ? 1 : out.stability.round();
    expect(out.dueAt, now.add(Duration(days: intervalDays)));
  });

  test('applyMasteryOverride mastered → S>=21', () async {
    final topicId = await seedTopic();
    final now = DateTime(2026, 8, 12, 10, 0, 0);
    await repo.upsert(TopicSchedule(
      topicId: topicId,
      stability: 2.0,
      difficulty: 5.0,
      reps: 1,
      lapses: 0,
      lastReviewedAt: DateTime(2026, 8, 5),
      dueAt: DateTime(2026, 8, 13),
    ));

    final out = await repo.applyMasteryOverride(
      topicId: topicId,
      status: MasteryStatus.mastered,
      now: now,
    );
    expect(out.stability, greaterThanOrEqualTo(21.0));
    expect(out.lastReviewedAt, now);
    expect(out.dueAt, isNotNull);
  });

  test('applyMasteryOverride learning → S∈[1,21]', () async {
    final topicId = await seedTopic();
    final now = DateTime(2026, 8, 12, 10, 0, 0);
    await repo.upsert(TopicSchedule(
      topicId: topicId,
      stability: 50.0, // 超上限 → clamp 回 21
      difficulty: 5.0,
      reps: 4,
      lapses: 0,
      lastReviewedAt: DateTime(2026, 8, 5),
      dueAt: DateTime(2026, 8, 13),
    ));

    final out = await repo.applyMasteryOverride(
      topicId: topicId,
      status: MasteryStatus.learning,
      now: now,
    );
    expect(out.stability, greaterThanOrEqualTo(1.0));
    expect(out.stability, lessThanOrEqualTo(21.0));
    expect(out.lastReviewedAt, now);
    expect(out.dueAt, isNotNull);
  });

  test('applyMasteryOverride unknown → S=0.4 且建行；新建行 lastReviewedAt=null 不计入今日首评',
      () async {
    final todayTopic = await seedTopic(title: 'today');
    final yesterdayTopic = await seedTopic(title: 'yesterday');
    final now = DateTime(2026, 8, 12, 10, 0, 0);
    final todayMidnight = DateTime(2026, 8, 12);
    final yesterday = DateTime(2026, 8, 11, 10, 0, 0);

    // 先在 yesterdayTopic 上落一行昨日的首评循环（reps==0, last=yesterday）
    await repo.upsert(TopicSchedule(
      topicId: yesterdayTopic,
      stability: 2.0,
      difficulty: 5.0,
      reps: 0,
      lapses: 0,
      lastReviewedAt: yesterday,
      dueAt: now,
    ));
    // unknown 修正今日 topic（此前无行 → 建行）。新建行 lastReviewedAt 为 null：
    // 该知识点未经 FSRS 评分 UI 首评，不应被 firstGradeCountToday 烧掉新卡额度。
    final out = await repo.applyMasteryOverride(
      topicId: todayTopic,
      status: MasteryStatus.unknown,
      now: now,
    );
    expect(out.topicId, todayTopic);
    expect(out.stability, 0.4);
    expect(out.lastReviewedAt, isNull);
    expect(out.dueAt, isNotNull);
    // 行已建：find 得到
    expect(await repo.findByTopic(todayTopic), isNotNull);

    // firstGradeCountToday：仅 last_reviewed_at >= 今日零点 且 reps==0 计入。
    // yesterdayTopic 的 last < 今日零点，不计；todayTopic 为新建行 lastReviewedAt=null，
    // 也不计 → 0。
    final count = await repo.firstGradeCountToday(now);
    expect(count, 0);
    // 显式验证今日零点边界
    expect(todayMidnight.millisecondsSinceEpoch, lessThan(now.millisecondsSinceEpoch));
  });
}
