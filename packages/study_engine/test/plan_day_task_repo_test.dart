import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';
import 'package:study_engine/study_engine.dart';

Future<StudyDatabase> _fresh() {
  sqfliteFfiInit();
  return StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
}

void main() {
  late StudyDatabase sdb;
  late PlanRepository plans;
  late PlanDayTaskRepository repo;
  late int planId;

  setUp(() async {
    sdb = await _fresh();
    plans = PlanRepository(sdb);
    repo = PlanDayTaskRepository(sdb);
    final now = DateTime.now();
    planId = await plans.insertPlan(Plan(
      name: '考研',
      examDate: DateTime(2026, 12, 21),
      examContent: '408',
      target: '380',
      dailyMinutes: 180,
      currentLevel: '估 300 分',
      createdAt: now,
      updatedAt: now,
    ));
  });
  tearDown(() async => await sdb.close());

  PlanDayTask mk(String title, DateTime date, {int sort = 0}) => PlanDayTask(
        planId: planId,
        taskDate: date,
        title: title,
        sortOrder: sort,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

  test('addTask + findByPlanAndDate 按本地日归一化', () async {
    // 同一天不同时间写入应被 findByPlanAndDate 合并查到
    await repo.addTask(mk('极限30题', DateTime(2026, 8, 12, 9, 0)));
    await repo.addTask(mk('线代基础', DateTime(2026, 8, 12, 21, 0), sort: 1));
    await repo.addTask(mk('英语阅读', DateTime(2026, 8, 13, 10, 0)));
    final day1 = await repo.findByPlanAndDate(planId, DateTime(2026, 8, 12));
    expect(day1.map((t) => t.title), ['极限30题', '线代基础']);
    final day2 = await repo.findByPlanAndDate(planId, DateTime(2026, 8, 13));
    expect(day2, hasLength(1));
  });

  test('checkin status=done 自动写 done_at；回 pending 清 done_at', () async {
    final id = await repo.addTask(mk('极限30题', DateTime(2026, 8, 12)));
    await repo.updateTask(id, status: 'done');
    var t = (await repo.findByPlanAndDate(planId, DateTime(2026, 8, 12))).first;
    expect(t.status, 'done');
    expect(t.doneAt, isNotNull);
    await repo.updateTask(id, status: 'pending');
    t = (await repo.findByPlanAndDate(planId, DateTime(2026, 8, 12))).first;
    expect(t.status, 'pending');
    expect(t.doneAt, isNull);
  });

  test('deleteTask 单条删除', () async {
    final id = await repo.addTask(mk('极限30题', DateTime(2026, 8, 12)));
    await repo.deleteTask(id);
    expect(await repo.findByPlanAndDate(planId, DateTime(2026, 8, 12)), isEmpty);
  });

  test('deletePlan CASCADE 清掉 plan_day_task', () async {
    await repo.addTask(mk('极限30题', DateTime(2026, 8, 12)));
    await plans.deletePlan(planId);
    expect(await repo.findByPlan(planId), isEmpty);
  });

  test('countDoneBetween 统计区间', () async {
    await repo.addTask(mk('a', DateTime(2026, 8, 10)));
    await repo.addTask(mk('b', DateTime(2026, 8, 11)));
    await repo.addTask(mk('c', DateTime(2026, 8, 12)));
    final id = await repo.addTask(mk('d', DateTime(2026, 8, 13)));
    await repo.updateTask(id, status: 'done');
    final r = await repo.countDoneBetween(planId, DateTime(2026, 8, 10), DateTime(2026, 8, 12));
    expect(r.total, 3);
    expect(r.done, 0);
    final r2 = await repo.countDoneBetween(planId, DateTime(2026, 8, 10), DateTime(2026, 8, 13));
    expect(r2.total, 4);
    expect(r2.done, 1);
  });

  test('findByPlan 按 task_date + sort_order 排序', () async {
    await repo.addTask(mk('c', DateTime(2026, 8, 13)));
    await repo.addTask(mk('a', DateTime(2026, 8, 12), sort: 2));
    await repo.addTask(mk('b', DateTime(2026, 8, 12), sort: 1));
    final all = await repo.findByPlan(planId);
    expect(all.map((t) => t.title), ['b', 'a', 'c']);
  });
}