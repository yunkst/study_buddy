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

  Future<void> seedTopic(StudyDatabase sdb, String title,
      {String question = 'q', String summary = 's'}) async {
    final catId = await CategoryRepository(sdb).ensurePath(['数学']);
    await TopicRepository(sdb).insert(Topic(
      categoryId: catId,
      title: title,
      question: question,
      summary: summary,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    ));
  }

  test('recommend_topics 空库返回空 items', () async {
    final sdb = await StudyDatabase.open(
        factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final scenario = buildScenario(sdb);

    final out = await scenario.executeTool('recommend_topics', {
      'keyword': '洛必达',
    });
    final json = jsonDecode(out) as Map<String, dynamic>;

    expect(json['items'] as List, isEmpty);

    await sdb.close();
  });

  test('recommend_topics 返回 id/title/path 且标题命中靠前', () async {
    final sdb = await StudyDatabase.open(
        factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final scenario = buildScenario(sdb);
    await seedTopic(sdb, '洛必达法则', summary: '0/0 型对分子分母求导'); // title 命中
    await seedTopic(sdb, '未定式极限', summary: '洛必达法则失效可等价替换'); // summary 命中

    final out = await scenario.executeTool('recommend_topics', {
      'keyword': '洛必达',
    });
    final json = jsonDecode(out) as Map<String, dynamic>;
    final items = (json['items'] as List).cast<Map<String, dynamic>>();

    expect(items, hasLength(2));
    expect(items.first['title'], '洛必达法则'); // 标题命中优先展示
    expect(items.first['id'], isA<int>());
    expect(items.first['path'], '数学');
    expect(items.last['title'], '未定式极限');

    await sdb.close();
  });

  test('recommend_topics 缺 keyword 返回友好错误', () async {
    final sdb = await StudyDatabase.open(
        factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final scenario = buildScenario(sdb);

    final out = await scenario.executeTool('recommend_topics', {});

    expect(out, contains('keyword'));

    await sdb.close();
  });
}