import 'dart:convert';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:study_engine/study_engine.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  StudyPlanScenario buildScenario(StudyDatabase sdb) => StudyPlanScenario(
        categories: CategoryRepository(sdb),
        topics: TopicRepository(sdb),
        edges: TopicEdgeRepository(sdb),
        memories: AgentMemoryRepository(sdb),
        mastery: MasteryRepository(sdb),
        reviews: ReviewRepository(sdb),
        schedules: TopicScheduleRepository(sdb),
        plans: PlanRepository(sdb),
        dayTasks: PlanDayTaskRepository(sdb),
      );

  test('save_topic 新建 → is_new=true 且 id 为 int', () async {
    final sdb = await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final scenario = buildScenario(sdb);

    final out = await scenario.executeTool('save_topic', {
      'path': '数学/高等数学/极限',
      'title': '洛必达法则',
      'question': '如何求0/0型极限?',
      'summary': '对分子分母分别求导后取极限',
    });
    final json = jsonDecode(out) as Map<String, dynamic>;
    expect(json['is_new'], isTrue);
    expect(json['id'], isA<int>());

    await sdb.close();
  });

  test('save_topic 重复 title → is_new=false 且 id 与第一次一致', () async {
    final sdb = await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final scenario = buildScenario(sdb);

    final first = jsonDecode(await scenario.executeTool('save_topic', {
      'path': '数学',
      'title': '极限',
      'question': 'q',
      'summary': 's',
    })) as Map<String, dynamic>;

    final second = jsonDecode(await scenario.executeTool('save_topic', {
      'path': '物理',
      'title': '极限',
      'question': 'q2',
      'summary': 's2',
    })) as Map<String, dynamic>;

    expect(second['is_new'], isFalse);
    expect(second['id'], first['id']);

    await sdb.close();
  });

  test('save_topic path 空 → id=null 且 msg 含 path', () async {
    final sdb = await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final scenario = buildScenario(sdb);

    final out = await scenario.executeTool('save_topic', {
      'path': '',
      'title': '极限',
      'question': 'q',
      'summary': 's',
    });
    final json = jsonDecode(out) as Map<String, dynamic>;
    expect(json['id'], isNull);
    expect(json['msg'], contains('path'));

    await sdb.close();
  });

  /// 断言默认 schedule 行字段：S=0、D=5、reps=0、lapses=0、lastReviewedAt=null、dueAt<=now。
  void expectDefaultScheduleRow(TopicSchedule? s) {
    expect(s, isNotNull);
    expect(s!.stability, 0);
    expect(s.difficulty, 5.0);
    expect(s.reps, 0);
    expect(s.lapses, 0);
    expect(s.lastReviewedAt, isNull);
    expect(s.dueAt, isNotNull);
    expect(s.dueAt!.isBefore(DateTime.now().add(const Duration(seconds: 1))), isTrue);
  }

  test('save_topic 新建 → 建默认 schedule 行（S=0/D=5/reps=0/lastReviewedAt=null/dueAt<=now）',
      () async {
    final sdb = await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final scenario = buildScenario(sdb);
    final schedules = TopicScheduleRepository(sdb);

    final json = jsonDecode(await scenario.executeTool('save_topic', {
      'path': '数学',
      'title': '导数定义',
      'question': 'q',
      'summary': 's',
    })) as Map<String, dynamic>;
    final id = json['id'] as int;

    expectDefaultScheduleRow(await schedules.findByTopic(id));

    await sdb.close();
  });

  test('save_topic 命中已存在但无 schedule 行 → 补建默认 schedule 行', () async {
    final sdb = await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final scenario = buildScenario(sdb);
    final topics = TopicRepository(sdb);
    final schedules = TopicScheduleRepository(sdb);

    // 先直接插一个 topic（绕过 save_topic，确保无 schedule 行）。
    final catId = await CategoryRepository(sdb).ensurePath(['数学']);
    final existingId = await topics.insert(Topic(
      categoryId: catId,
      title: '夹逼准则',
      question: 'q',
      summary: 's',
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    ));
    expect(await schedules.findByTopic(existingId), isNull);

    // save_topic 命中已存在 → force=false 补建默认行。
    final json = jsonDecode(await scenario.executeTool('save_topic', {
      'path': '数学',
      'title': '夹逼准则',
      'question': 'q',
      'summary': 's',
    })) as Map<String, dynamic>;
    expect(json['is_new'], isFalse);

    expectDefaultScheduleRow(await schedules.findByTopic(existingId));

    await sdb.close();
  });

  test('save_topic 命中已存在且已有 schedule 行 → 不覆盖历史 FSRS 状态', () async {
    final sdb = await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final scenario = buildScenario(sdb);
    final schedules = TopicScheduleRepository(sdb);

    // 首次 save_topic 建默认行。
    final first = jsonDecode(await scenario.executeTool('save_topic', {
      'path': '数学',
      'title': '中值定理',
      'question': 'q',
      'summary': 's',
    })) as Map<String, dynamic>;
    final id = first['id'] as int;

    // 模拟历史 FSRS 状态：手动覆盖成已复习卡（reps=3, S=10, dueAt 远未来）。
    await schedules.upsert(TopicSchedule(
      topicId: id,
      stability: 10.0,
      difficulty: 6.0,
      reps: 3,
      lapses: 1,
      lastReviewedAt: DateTime.now(),
      dueAt: DateTime.now().add(const Duration(days: 9)),
    ));

    // 再次 save_topic 同 title（命中已存在 + 已有行）→ 不应覆盖。
    await scenario.executeTool('save_topic', {
      'path': '数学',
      'title': '中值定理',
      'question': 'q',
      'summary': 's',
    });

    final after = await schedules.findByTopic(id);
    expect(after!.stability, 10.0);
    expect(after.difficulty, 6.0);
    expect(after.reps, 3);
    expect(after.lapses, 1);
    expect(after.lastReviewedAt, isNotNull);

    await sdb.close();
  });
}