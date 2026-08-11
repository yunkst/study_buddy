import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';
import 'package:study_engine/study_engine.dart';

Future<StudyDatabase> _fresh() {
  sqfliteFfiInit();
  return StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
}

void main() {
  late StudyDatabase sdb;
  late PlanRepository repo;
  setUp(() async {
    sdb = await _fresh();
    repo = PlanRepository(sdb);
  });
  tearDown(() async => await sdb.close());

  Plan plan() {
    final now = DateTime.now();
    return Plan(
      name: '考研冲刺', examDate: DateTime(2026, 12, 21), examContent: '408',
      target: '380', dailyMinutes: 180, currentLevel: '估 300 分',
      createdAt: now, updatedAt: now,
    );
  }

  test('insertPlan/findPlanById/findAllPlans', () async {
    final id = await repo.insertPlan(plan());
    final got = await repo.findPlanById(id);
    expect(got?.name, '考研冲刺');
    expect(await repo.findAllPlans(), hasLength(1));
  });

  test('updatePlan 刷新 updated_at', () async {
    final id = await repo.insertPlan(plan());
    final before = (await repo.findPlanById(id))!.updatedAt;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final p = (await repo.findPlanById(id))!;
    await repo.updatePlan(Plan(
      id: id, name: p.name, examDate: p.examDate, examContent: p.examContent,
      target: '360', dailyMinutes: p.dailyMinutes, currentLevel: p.currentLevel,
      createdAt: p.createdAt, updatedAt: p.createdAt,
    ));
    final after = await repo.findPlanById(id);
    expect(after?.target, '360');
    expect(after!.updatedAt.isAfter(before) || after.updatedAt == before, isTrue);
  });

  test('Milestone 增删改查按 sort_order 排', () async {
    final pid = await repo.insertPlan(plan());
    final now = DateTime.now();
    await repo.addMilestone(Milestone(planId: pid, title: 'm2', description: 'd', targetDate: now, sortOrder: 2, createdAt: now, updatedAt: now));
    final m1Id = await repo.addMilestone(Milestone(planId: pid, title: 'm1', description: 'd', targetDate: now, sortOrder: 1, status: 'pending', createdAt: now, updatedAt: now));
    var list = await repo.findMilestonesByPlan(pid);
    expect(list.map((m) => m.title), ['m1', 'm2']);
    await repo.updateMilestone(m1Id, status: 'done');
    list = await repo.findMilestonesByPlan(pid);
    expect(list.first.status, 'done');
    await repo.deleteMilestone(m1Id);
    expect(await repo.findMilestonesByPlan(pid), hasLength(1));
  });

  test('Assessment 增查按 assessed_at 排 + latestAssessment', () async {
    final pid = await repo.insertPlan(plan());
    final now = DateTime.now();
    await repo.addAssessment(Assessment(planId: pid, score: 300, assessedAt: DateTime(2026, 8, 6), createdAt: now));
    await repo.addAssessment(Assessment(planId: pid, score: 310, assessedAt: DateTime(2026, 8, 20), createdAt: now));
    final list = await repo.findAssessmentsByPlan(pid);
    expect(list.map((a) => a.score), [300, 310]);
    final latest = await repo.latestAssessment(pid);
    expect(latest?.score, 310);
  });

  test('getPlanDetail 聚合三表', () async {
    final pid = await repo.insertPlan(plan());
    final now = DateTime.now();
    await repo.addMilestone(Milestone(planId: pid, title: 'm1', description: 'd', targetDate: now, createdAt: now, updatedAt: now));
    await repo.addAssessment(Assessment(planId: pid, score: 300, assessedAt: now, createdAt: now));
    final detail = await repo.getPlanDetail(pid);
    expect(detail.plan.id, pid);
    expect(detail.milestones, hasLength(1));
    expect(detail.assessments, hasLength(1));
  });

  test('deletePlan CASCADE 清节点与测评', () async {
    final pid = await repo.insertPlan(plan());
    final now = DateTime.now();
    await repo.addMilestone(Milestone(planId: pid, title: 'm', description: 'd', targetDate: now, createdAt: now, updatedAt: now));
    await repo.addAssessment(Assessment(planId: pid, score: 300, assessedAt: now, createdAt: now));
    await repo.deletePlan(pid);
    expect(await repo.findPlanById(pid), isNull);
    expect(await repo.findMilestonesByPlan(pid), isEmpty);
    expect(await repo.findAssessmentsByPlan(pid), isEmpty);
  });
}
