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
}