import 'dart:convert';

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
      dayTasks: PlanDayTaskRepository(sdb),
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

  test('场景9 delete_plan 删干净 plan/milestone/assessment', () async {
    final sdb = await _fresh();
    final scenario = newScenario(sdb);
    final repo = PlanRepository(sdb);

    await scenario.executeTool('create_plan', {
      'name': '考研', 'exam_date': '2026-12-21', 'exam_content': '408',
      'target': '380', 'daily_minutes': 180, 'current_level': '估 300 分',
    });
    final pid = (await repo.findAllPlans()).first.id!;
    await scenario.executeTool('add_milestone', {
      'plan_id': pid, 'title': 'm1', 'description': 'd', 'target_date': '2026-09-30',
    });
    await scenario.executeTool('add_assessment', {
      'plan_id': pid, 'score': 320, 'note': '进展',
    });

    final result = await scenario.executeTool('delete_plan', {'plan_id': pid});
    expect(result, contains('已删除计划'));
    final json = jsonDecode(result) as Map<String, dynamic>;
    expect(json['ok'], true);
    expect(json['plan_id'], pid);
    // CASCADE 清干净
    expect(await repo.findAllPlans(), isEmpty);
    expect(await repo.findMilestonesByPlan(pid), isEmpty);
    expect(await repo.findAssessmentsByPlan(pid), isEmpty);
    await sdb.close();
  });

  test('场景10 delete_assessment 只删指定条', () async {
    final sdb = await _fresh();
    final scenario = newScenario(sdb);
    final repo = PlanRepository(sdb);

    await scenario.executeTool('create_plan', {
      'name': '考研', 'exam_date': '2026-12-21', 'exam_content': '408',
      'target': '380', 'daily_minutes': 180, 'current_level': '估 300 分',
    });
    final pid = (await repo.findAllPlans()).first.id!;
    // create_plan 已自动生成起点测评(score=300)；再加一条 320
    final ar = await scenario.executeTool('add_assessment', {
      'plan_id': pid, 'score': 320, 'note': '进展',
    });
    final json = jsonDecode(ar) as Map<String, dynamic>;
    final aid = json['assessment_id'] as int;

    final del = await scenario.executeTool('delete_assessment', {'assessment_id': aid});
    expect(del, contains('已删除测评'));
    // 删的是 320；起点 300 还在
    final list = await repo.findAssessmentsByPlan(pid);
    expect(list, hasLength(1));
    expect(list.first.score, 300);
    await sdb.close();
  });

  test('场景11 create_day_task → checkin_day_task → list_day_tasks', () async {
    final sdb = await _fresh();
    final scenario = newScenario(sdb);
    final repo = PlanRepository(sdb);
    final dayRepo = PlanDayTaskRepository(sdb);

    await scenario.executeTool('create_plan', {
      'name': '考研', 'exam_date': '2026-12-21', 'exam_content': '408',
      'target': '380', 'daily_minutes': 180, 'current_level': '估 300 分',
    });
    final pid = (await repo.findAllPlans()).first.id!;
    await scenario.executeTool('create_day_task', {
      'plan_id': pid, 'task_date': '2026-08-12', 'title': '极限30题',
    });
    await scenario.executeTool('create_day_task', {
      'plan_id': pid, 'task_date': '2026-08-12', 'title': '线代基础',
    });
    await scenario.executeTool('create_day_task', {
      'plan_id': pid, 'task_date': '2026-08-13', 'title': '英语阅读',
    });

    // list_day_tasks 含 task_date
    final list = await scenario.executeTool('list_day_tasks', {
      'plan_id': pid, 'task_date': '2026-08-12',
    });
    expect(list, contains('极限30题'));
    expect(list, contains('线代基础'));
    expect(list, isNot(contains('英语阅读')));

    // checkin
    final firstId = (await dayRepo.findByPlanAndDate(pid, DateTime(2026, 8, 12))).first.id!;
    final ck = await scenario.executeTool('checkin_day_task', {
      'task_id': firstId, 'status': 'done',
    });
    expect(ck, contains('done'));
    final ckFirst = (await dayRepo.findByPlanAndDate(pid, DateTime(2026, 8, 12))).first;
    expect(ckFirst.status, 'done');
    expect(ckFirst.doneAt, isNotNull);

    // 非法 status 拒绝
    final bad = await scenario.executeTool('checkin_day_task', {
      'task_id': firstId, 'status': 'xxx',
    });
    expect(bad, contains('status'));
    await sdb.close();
  });

  test('场景12 delete_day_task 删单条 + update_day_task 改字段', () async {
    final sdb = await _fresh();
    final scenario = newScenario(sdb);
    final repo = PlanRepository(sdb);
    final dayRepo = PlanDayTaskRepository(sdb);

    await scenario.executeTool('create_plan', {
      'name': '考研', 'exam_date': '2026-12-21', 'exam_content': '408',
      'target': '380', 'daily_minutes': 180, 'current_level': '估 300 分',
    });
    final pid = (await repo.findAllPlans()).first.id!;
    await scenario.executeTool('create_day_task', {
      'plan_id': pid, 'task_date': '2026-08-12', 'title': '原标题',
    });
    final id = (await dayRepo.findByPlanAndDate(pid, DateTime(2026, 8, 12))).first.id!;

    // update 改标题
    await scenario.executeTool('update_day_task', {
      'task_id': id, 'title': '新标题',
    });
    expect((await dayRepo.findByPlanAndDate(pid, DateTime(2026, 8, 12))).first.title, '新标题');

    // delete
    final del = await scenario.executeTool('delete_day_task', {'task_id': id});
    expect(del, contains('已删除每日任务'));
    expect(await dayRepo.findByPlanAndDate(pid, DateTime(2026, 8, 12)), isEmpty);
    await sdb.close();
  });

  test('场景13 delete_plan 级联清 plan_day_task', () async {
    final sdb = await _fresh();
    final scenario = newScenario(sdb);
    final repo = PlanRepository(sdb);
    final dayRepo = PlanDayTaskRepository(sdb);

    await scenario.executeTool('create_plan', {
      'name': '考研', 'exam_date': '2026-12-21', 'exam_content': '408',
      'target': '380', 'daily_minutes': 180, 'current_level': '估 300 分',
    });
    final pid = (await repo.findAllPlans()).first.id!;
    await scenario.executeTool('create_day_task', {
      'plan_id': pid, 'task_date': '2026-08-12', 'title': '极限30题',
    });

    final result = await scenario.executeTool('delete_plan', {'plan_id': pid});
    // message 含每日任务计数（不是 0）
    expect(result, contains('每日任务'));
    final json = jsonDecode(result) as Map<String, dynamic>;
    final msg = json['message'] as String;
    expect(msg, contains('1 每日任务'));
    expect(await dayRepo.findByPlan(pid), isEmpty);
    await sdb.close();
  });
}
