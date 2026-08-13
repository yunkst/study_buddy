import 'dart:convert';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:study_engine/study_engine.dart';
import 'package:test/test.dart';

/// delete_topic / delete_category 工具的 scenario 集成测试。
///
/// 验证：
/// - delete_topic 按 id / title 删除，二者皆缺则拒绝；删后数据消失。
/// - delete_category 按 path 删整棵子树，返回受影响计数；路径不存在则拒绝不报错。
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

  /// 建一棵子树：数学/高等数学/极限 下挂「极限定义」「洛必达」，物理/力学 挂「牛顿定律」。
  /// 返回相关 id 供断言。
  Future<({StudyPlanScenario scenario, int defId, int lhopId, int newtonId})> seed(
      StudyPlanScenario scenario) async {
    final defOut = jsonDecode(await scenario.executeTool('save_topic', {
      'path': '数学/高等数学/极限',
      'title': '极限定义',
      'question': 'q',
      'summary': 's',
    })) as Map<String, dynamic>;
    final lhopOut = jsonDecode(await scenario.executeTool('save_topic', {
      'path': '数学/高等数学/极限',
      'title': '洛必达法则',
      'question': 'q',
      'summary': 's',
    })) as Map<String, dynamic>;
    final newtonOut = jsonDecode(await scenario.executeTool('save_topic', {
      'path': '物理/力学',
      'title': '牛顿定律',
      'question': 'q',
      'summary': 's',
    })) as Map<String, dynamic>;
    return (
      scenario: scenario,
      defId: defOut['id'] as int,
      lhopId: lhopOut['id'] as int,
      newtonId: newtonOut['id'] as int,
    );
  }

  group('delete_topic', () {
    test('按 id 删除', () async {
      final sdb = await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
      final scenario = buildScenario(sdb);
      final s = await seed(scenario);

      final out = jsonDecode(await scenario.executeTool('delete_topic', {'id': s.defId}))
          as Map<String, dynamic>;
      expect(out['ok'], isTrue);
      expect(out['deleted'], isTrue);

      // 确认已删，且兄弟知识点/其它学科不受影响
      final getRes = await scenario.executeTool('get_topic', {'id': s.defId});
      expect(getRes, contains('不存在'));
      expect(await scenario.executeTool('get_topic', {'id': s.lhopId}), isNot(contains('不存在')));

      await sdb.close();
    });

    test('按 title 删除', () async {
      final sdb = await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
      final scenario = buildScenario(sdb);
      await seed(scenario);

      final out = jsonDecode(await scenario.executeTool('delete_topic', {'title': '洛必达法则'}))
          as Map<String, dynamic>;
      expect(out['ok'], isTrue);
      expect(out['deleted'], isTrue);

      await sdb.close();
    });

    test('id 与 title 都缺 → 拒绝', () async {
      final sdb = await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
      final scenario = buildScenario(sdb);
      await seed(scenario);

      final out = jsonDecode(await scenario.executeTool('delete_topic', {}))
          as Map<String, dynamic>;
      expect(out['ok'], isFalse);
      expect(out['deleted'], isFalse);

      await sdb.close();
    });

    test('不存在的 id → 未删除不报错', () async {
      final sdb = await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
      final scenario = buildScenario(sdb);

      final out = jsonDecode(await scenario.executeTool('delete_topic', {'id': 99999}))
          as Map<String, dynamic>;
      expect(out['ok'], isFalse);
      expect(out['deleted'], isFalse);

      await sdb.close();
    });
  });

  group('delete_category', () {
    test('按 path 删整棵子树', () async {
      final sdb = await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
      final scenario = buildScenario(sdb);
      final s = await seed(scenario);

      final out = jsonDecode(await scenario.executeTool('delete_category', {'path': '数学'}))
          as Map<String, dynamic>;
      expect(out['ok'], isTrue);
      expect(out['deleted_categories'], 3); // 数学、高等数学、极限
      expect(out['deleted_topics'], 2); // 极限定义、洛必达

      // 子树下知识点没了，物理分支保留
      expect(await scenario.executeTool('get_topic', {'id': s.defId}), contains('不存在'));
      expect(await scenario.executeTool('get_topic', {'id': s.newtonId}), isNot(contains('不存在')));

      await sdb.close();
    });

    test('path 不存在 → ok=false 不报错', () async {
      final sdb = await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
      final scenario = buildScenario(sdb);

      final out = jsonDecode(await scenario.executeTool('delete_category', {'path': '不存在/路径'}))
          as Map<String, dynamic>;
      expect(out['ok'], isFalse);

      await sdb.close();
    });
  });
}
