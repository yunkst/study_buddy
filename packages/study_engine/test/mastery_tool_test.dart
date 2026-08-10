import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';
import 'package:study_engine/study_engine.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  // 与 study_scenario_integration_test 同款装配，多了 mastery / reviews
  Future<(StudyScenario, MasteryRepository, TopicRepository, StudyDatabase)> setup() async {
    final sdb = await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final scenario = StudyScenario(
      categories: CategoryRepository(sdb),
      topics: TopicRepository(sdb),
      edges: TopicEdgeRepository(sdb),
      memories: AgentMemoryRepository(sdb),
      mastery: MasteryRepository(sdb),
      reviews: ReviewRepository(sdb), // Task 3 才有实现，本 Task 用占位桩
    );
    return (scenario, MasteryRepository(sdb), TopicRepository(sdb), sdb);
  }

  test('set_mastery 落库并更新 currentStatus', () async {
    final (scenario, mastery, topics, sdb) = await setup();
    // 先建一个 topic 拿 id
    await scenario.executeTool('save_topic', {
      'path': '数学', 'title': '极限', 'question': 'q', 'summary': 's',
    });
    final t = await topics.findByTitle('极限');
    expect(t, isNotNull);

    final r = await scenario.executeTool('set_mastery', {
      'topic_id': t!.id, 'status': 'weak', 'reason': '求极限题答错',
    });
    expect(r, contains('已记录'));
    expect(await mastery.currentStatus(t.id!), MasteryStatus.weak);
    await sdb.close();
  });

  test('set_mastery 覆盖:再调 learning 后 currentStatus 变 learning', () async {
    final (scenario, mastery, topics, sdb) = await setup();
    await scenario.executeTool('save_topic', {'path': '数学', 'title': '导数', 'question': 'q', 'summary': 's'});
    final t = await topics.findByTitle('导数');

    await scenario.executeTool('set_mastery', {'topic_id': t!.id, 'status': 'weak', 'reason': 'r1'});
    await scenario.executeTool('set_mastery', {'topic_id': t.id, 'status': 'learning', 'reason': 'r2'});
    expect(await mastery.currentStatus(t.id!), MasteryStatus.learning);
    await sdb.close();
  });

  test('set_mastery 非法 status 被拒', () async {
    final (scenario, _, topics, sdb) = await setup();
    await scenario.executeTool('save_topic', {'path': '数学', 'title': '积分', 'question': 'q', 'summary': 's'});
    final t = await topics.findByTitle('积分');
    final r = await scenario.executeTool('set_mastery', {
      'topic_id': t!.id, 'status': 'unknown', 'reason': 'r',
    });
    expect(r, contains('status')); // 错误信息提示 status 不合法
    await sdb.close();
  });

  test('get_mastery 返回 current_status 与 recent reason', () async {
    final (scenario, _, topics, sdb) = await setup();
    await scenario.executeTool('save_topic', {'path': '数学', 'title': '连续', 'question': 'q', 'summary': 's'});
    final t = await topics.findByTitle('连续');
    await scenario.executeTool('set_mastery', {'topic_id': t!.id, 'status': 'weak', 'reason': '答错'});
    final r = await scenario.executeTool('get_mastery', {'topic_id': t.id});
    expect(r, contains('"current_status"'));
    expect(r, contains('weak'));
    expect(r, contains('答错'));
    await sdb.close();
  });
}
