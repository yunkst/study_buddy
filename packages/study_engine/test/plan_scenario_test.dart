import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';
import 'package:study_engine/study_engine.dart';

/// PlanScenario 工具执行测试。通过 executeTool 直接触发，验证 create_plan
/// 从 current_level 抽起点分数的语义（_extractScore 不再把日期/时长误判为分数）。
void main() {
  setUpAll(sqfliteFfiInit);

  Future<StudyDatabase> openDb() => StudyDatabase.open(
        factory: databaseFactoryFfi,
        path: inMemoryDatabasePath,
      );

  PlanScenario newScenario(StudyDatabase sdb) => PlanScenario(
        plans: PlanRepository(sdb),
        memories: AgentMemoryRepository(sdb),
      );

  test('_extractScore 不把日期/时长误判为分数', () async {
    final sdb = await openDb();
    final scenario = newScenario(sdb);

    // current_level 含年份但无"分"，不应抽成 score=2024，应返回 null（note 保留原文）。
    final r1 = await scenario.executeTool('create_plan', {
      'name': '考研',
      'exam_date': '2026-12-21',
      'exam_content': '数学一',
      'target': '上岸',
      'daily_minutes': 240,
      'current_level': '最近做2024年真题，感觉概率论薄弱',
    });
    final id1 = r1.contains('plan_id') ? int.parse(RegExp(r'"plan_id":\s*(\d+)').firstMatch(r1)!.group(1)!) : -1;
    final detail1 = await PlanRepository(sdb).getPlanDetail(id1);
    // 抽不到分数 → 起点测评 score 为 null
    expect(detail1.assessments.first.score, isNull,
        reason: '"2024年真题"中的 2024 不应被当成起点分数');
    await sdb.close();
  });

  test('_extractScore 命中"X分"模式时正常抽分', () async {
    final sdb = await openDb();
    final scenario = newScenario(sdb);

    final r = await scenario.executeTool('create_plan', {
      'name': '考研',
      'exam_date': '2026-12-21',
      'exam_content': '数学一',
      'target': '上岸',
      'daily_minutes': 240,
      'current_level': '最近做真题能考90分，概率论薄弱',
    });
    final id = int.parse(RegExp(r'"plan_id":\s*(\d+)').firstMatch(r)!.group(1)!);
    final detail = await PlanRepository(sdb).getPlanDetail(id);
    expect(detail.assessments.first.score, 90);
    await sdb.close();
  });
}
