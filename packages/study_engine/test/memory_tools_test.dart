import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';
import 'package:study_engine/study_engine.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  StudyPlanScenario newScenario(StudyDatabase sdb) => StudyPlanScenario(
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

  test('add 新增成功', () async {
    final sdb = await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final sc = newScenario(sdb);
    final r = await sc.executeTool('patch_memory', {'action': 'add', 'new_text': '用户偏好简短回答'});
    expect(r, contains('已新增记忆'));
    final mems = await AgentMemoryRepository(sdb).queryByScenario('study_plan');
    expect(mems.single.content, '用户偏好简短回答');
    await sdb.close();
  });

  test('add 空内容被拒', () async {
    final sdb = await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final sc = newScenario(sdb);
    final r = await sc.executeTool('patch_memory', {'action': 'add', 'new_text': '   '});
    expect(r, contains('不能为空'));
    expect(await AgentMemoryRepository(sdb).queryByScenario('study_plan'), isEmpty);
    await sdb.close();
  });

  test('add 重复内容跳过', () async {
    final sdb = await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final sc = newScenario(sdb);
    await sc.executeTool('patch_memory', {'action': 'add', 'new_text': '偏好A'});
    final r = await sc.executeTool('patch_memory', {'action': 'add', 'new_text': '偏好A'});
    expect(r, contains('重复'));
    expect((await AgentMemoryRepository(sdb).queryByScenario('study_plan')).length, 1);
    await sdb.close();
  });

  test('add 超限被拒且回滚（库不变）', () async {
    final sdb = await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final sc = newScenario(sdb);
    // 先填到接近上限：一条 1900 字符。
    await sc.executeTool('patch_memory', {'action': 'add', 'new_text': List.filled(1900, 'x').join()});
    final r = await sc.executeTool('patch_memory', {'action': 'add', 'new_text': List.filled(200, 'y').join()});
    expect(r, contains('超容量上限'));
    // 库仍是 1 条（回滚，新条未写入）
    final mems = await AgentMemoryRepository(sdb).queryByScenario('study_plan');
    expect(mems.length, 1);
    expect(mems.single.content.length, 1900);
    await sdb.close();
  });

  test('replace 子串命中更新', () async {
    final sdb = await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final sc = newScenario(sdb);
    await sc.executeTool('patch_memory', {'action': 'add', 'new_text': '用户偏好简短回答'});
    final r = await sc.executeTool('patch_memory', {
      'action': 'replace', 'target_text': '简短回答', 'new_text': '用户偏好精炼回答',
    });
    expect(r, contains('已更新记忆'));
    final mems = await AgentMemoryRepository(sdb).queryByScenario('study_plan');
    expect(mems.single.content, '用户偏好精炼回答');
    await sdb.close();
  });

  test('replace 零命中报错并列表', () async {
    final sdb = await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final sc = newScenario(sdb);
    await sc.executeTool('patch_memory', {'action': 'add', 'new_text': '偏好A'});
    final r = await sc.executeTool('patch_memory', {
      'action': 'replace', 'target_text': '不存在的子串', 'new_text': 'X',
    });
    expect(r, contains('未找到'));
    expect(r, contains('[1]'));
    await sdb.close();
  });

  test('replace 多条命中报错', () async {
    final sdb = await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final sc = newScenario(sdb);
    await sc.executeTool('patch_memory', {'action': 'add', 'new_text': '偏好A包含abc'});
    await sc.executeTool('patch_memory', {'action': 'add', 'new_text': '偏好B包含abc'});
    final r = await sc.executeTool('patch_memory', {
      'action': 'replace', 'target_text': 'abc', 'new_text': 'X',
    });
    expect(r, contains('匹配到 2 条'));
    await sdb.close();
  });

  test('remove 命中删除', () async {
    final sdb = await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final sc = newScenario(sdb);
    await sc.executeTool('patch_memory', {'action': 'add', 'new_text': '偏好A'});
    final r = await sc.executeTool('patch_memory', {'action': 'remove', 'target_text': '偏好A'});
    expect(r, contains('已删除记忆'));
    expect(await AgentMemoryRepository(sdb).queryByScenario('study_plan'), isEmpty);
    await sdb.close();
  });

  test('缺 action 报参数缺失', () async {
    final sdb = await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final sc = newScenario(sdb);
    final r = await sc.executeTool('patch_memory', {'new_text': 'X'});
    expect(r, contains('action'));
    await sdb.close();
  });

  test('replace 空 target_text 被拒', () async {
    final sdb = await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final sc = newScenario(sdb);
    await sc.executeTool('patch_memory', {'action': 'add', 'new_text': '偏好A'});
    final r = await sc.executeTool('patch_memory', {
      'action': 'replace', 'target_text': '   ', 'new_text': 'X',
    });
    expect(r, contains('target_text'));
    // 库仍是 1 条原始记忆（未被空 target 替换第一条）
    final mems = await AgentMemoryRepository(sdb).queryByScenario('study_plan');
    expect(mems.single.content, '偏好A');
    await sdb.close();
  });

  test('replace 空 new_text 被拒', () async {
    final sdb = await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final sc = newScenario(sdb);
    await sc.executeTool('patch_memory', {'action': 'add', 'new_text': '用户偏好简短回答'});
    final r = await sc.executeTool('patch_memory', {
      'action': 'replace', 'target_text': '简短回答', 'new_text': '   ',
    });
    expect(r, contains('新内容不能为空'));
    // 库中该记忆内容未变（仍是原值，未被置空）
    final mems = await AgentMemoryRepository(sdb).queryByScenario('study_plan');
    expect(mems.single.content, '用户偏好简短回答');
    await sdb.close();
  });

  test('缓存同步：patch 后 composeApiMessages 记忆块反映新值', () async {
    final sdb = await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final sc = newScenario(sdb);
    await sc.getMemories(); // 预填充 _memCache（此时为空）
    await sc.executeTool('patch_memory', {'action': 'add', 'new_text': '偏好A'});
    // composeApiMessages 只读 _memCache 不重查库——此断言才是「patch 后刷新缓存」的真验证：
    // 若实现里丢了 if (changed) { _memCache = ... } 刷新逻辑，_memCache 仍为空，
    // composeApiMessages 会提前 return base，apiContent 为 null，此处断言即失败。
    final out = sc.composeApiMessages(
      [ChatMessage(role: 'user', content: '你好')],
      const AgentScenarioContext(),
    );
    expect(out.last.apiContent, contains('偏好A'));
    await sdb.close();
  });
}
