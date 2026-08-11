import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';
import 'package:study_engine/study_engine.dart';

Future<StudyDatabase> _fresh() {
  sqfliteFfiInit();
  return StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
}

PlanScenario newScenario(StudyDatabase sdb) => PlanScenario(
      plans: PlanRepository(sdb),
      memories: AgentMemoryRepository(sdb),
    );

void main() {
  setUpAll(sqfliteFfiInit);

  test('场景1 create_plan 收齐后落库 + 自动生成首条测评', () async {
    final sdb = await _fresh();
    final scenario = newScenario(sdb);
    final repo = PlanRepository(sdb);

    final result = await scenario.executeTool('create_plan', {
      'name': '考研冲刺',
      'exam_date': '2026-12-21',
      'exam_content': '408',
      'target': '380',
      'daily_minutes': 180,
      'current_level': '做真题估 300 分，数学最弱',
    });
    expect(result, contains('已创建'));

    final plans = await repo.findAllPlans();
    expect(plans, hasLength(1));
    final pid = plans.first.id!;
    // current_level "估 300 分" 抽出 300 作为起点测评
    final assessments = await repo.findAssessmentsByPlan(pid);
    expect(assessments, hasLength(1));
    expect(assessments.first.score, 300);
    await sdb.close();
  });

  test('场景2 create_plan current_level 抽不到分数时 score=null', () async {
    final sdb = await _fresh();
    final scenario = newScenario(sdb);
    final repo = PlanRepository(sdb);

    await scenario.executeTool('create_plan', {
      'name': '六级', 'exam_date': '2026-12-14', 'exam_content': '六级',
      'target': '过六级', 'daily_minutes': 60, 'current_level': '感觉听力还行，阅读差',
    });
    final pid = (await repo.findAllPlans()).first.id!;
    final a = (await repo.findAssessmentsByPlan(pid)).first;
    expect(a.score, isNull);
    expect(a.note, contains('听力'));
    await sdb.close();
  });

  test('场景3 create_plan 缺参数不落库（防御）', () async {
    final sdb = await _fresh();
    final scenario = newScenario(sdb);
    final repo = PlanRepository(sdb);

    final result = await scenario.executeTool('create_plan', {
      'name': '考研', 'exam_date': '2026-12-21',
      // 缺 exam_content/target/daily_minutes/current_level
    });
    expect(result, contains('缺少'));
    expect(await repo.findAllPlans(), isEmpty);
    await sdb.close();
  });

  test('场景4 add_milestone + get_plan 完整返回', () async {
    final sdb = await _fresh();
    final scenario = newScenario(sdb);
    final repo = PlanRepository(sdb);

    await scenario.executeTool('create_plan', {
      'name': '考研', 'exam_date': '2026-12-21', 'exam_content': '408',
      'target': '380', 'daily_minutes': 180, 'current_level': '估 300 分',
    });
    final pid = (await repo.findAllPlans()).first.id!;

    await scenario.executeTool('add_milestone', {
      'plan_id': pid, 'title': '数学基础', 'description': '高数线代基础课', 'target_date': '2026-09-30',
    });
    await scenario.executeTool('add_milestone', {
      'plan_id': pid, 'title': '真题一轮', 'description': '全科真题刷完', 'target_date': '2026-11-10',
    });

    final detail = await scenario.executeTool('get_plan', {'plan_id': pid});
    expect(detail, contains('数学基础'));
    expect(detail, contains('真题一轮'));
    expect(detail, contains('300'));
    await sdb.close();
  });

  test('场景5 update_milestone 状态切换 + 非法状态拒绝', () async {
    final sdb = await _fresh();
    final scenario = newScenario(sdb);
    final repo = PlanRepository(sdb);

    await scenario.executeTool('create_plan', {
      'name': '考研', 'exam_date': '2026-12-21', 'exam_content': '408',
      'target': '380', 'daily_minutes': 180, 'current_level': '估 300 分',
    });
    final pid = (await repo.findAllPlans()).first.id!;
    final msId = await repo.addMilestone(Milestone(
      planId: pid, title: 'm1', description: 'd', targetDate: DateTime(2026, 9, 30),
      createdAt: DateTime.now(), updatedAt: DateTime.now(),
    ));

    await scenario.executeTool('update_milestone', {'milestone_id': msId, 'status': 'done'});
    expect((await repo.findMilestonesByPlan(pid)).first.status, 'done');

    final bad = await scenario.executeTool('update_milestone', {'milestone_id': msId, 'status': 'xxx'});
    expect(bad, contains('status'));
    await sdb.close();
  });

  test('场景6 delete_milestone + add_assessment', () async {
    final sdb = await _fresh();
    final scenario = newScenario(sdb);
    final repo = PlanRepository(sdb);

    await scenario.executeTool('create_plan', {
      'name': '考研', 'exam_date': '2026-12-21', 'exam_content': '408',
      'target': '380', 'daily_minutes': 180, 'current_level': '估 300 分',
    });
    final pid = (await repo.findAllPlans()).first.id!;
    final msId = await repo.addMilestone(Milestone(
      planId: pid, title: 'm1', description: 'd', targetDate: DateTime(2026, 9, 30),
      createdAt: DateTime.now(), updatedAt: DateTime.now(),
    ));

    await scenario.executeTool('delete_milestone', {'milestone_id': msId});
    expect(await repo.findMilestonesByPlan(pid), isEmpty);

    final ar = await scenario.executeTool('add_assessment', {
      'plan_id': pid, 'score': 310, 'note': '线代崩了',
    });
    expect(ar, contains('310'));
    final list = await repo.findAssessmentsByPlan(pid);
    expect(list, hasLength(2)); // 起点 300 + 新 310
    expect(list.last.score, 310);
    await sdb.close();
  });

  test('场景7 buildSystemPrompt 含今天日期与计划概要', () async {
    final sdb = await _fresh();
    final scenario = newScenario(sdb);

    final ctx = AgentScenarioContext(extra: {
      'today': DateTime(2026, 8, 10),
      'plan_summary': '计划：考研冲刺，考试 2026-12-21，目标 380',
    });
    final prompt = scenario.buildSystemPrompt(ctx);
    expect(prompt, contains('2026-08-10'));
    expect(prompt, contains('考研冲刺'));
    expect(prompt, contains('create_plan'));
    await sdb.close();
  });

  test('场景8 create_plan current_level 含年份时优先抽"数字+分"', () async {
    final sdb = await _fresh();
    final scenario = newScenario(sdb);
    final repo = PlanRepository(sdb);

    await scenario.executeTool('create_plan', {
      'name': '考研', 'exam_date': '2026-12-21', 'exam_content': '408',
      'target': '380', 'daily_minutes': 180,
      'current_level': '2026 年估 300 分，数学最弱',
    });
    final pid = (await repo.findAllPlans()).first.id!;
    final a = (await repo.findAssessmentsByPlan(pid)).first;
    // 不能误抽年份 2026，应抽到 300
    expect(a.score, 300);
    expect(a.score, isNot(2026));
    await sdb.close();
  });
}
