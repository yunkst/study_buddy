import '../db/database.dart';
import '../models/plan_models.dart';

/// plan_day_task 仓储：每日打卡任务的持久化与查询。
///
/// 独立成文件（而非并入 [PlanRepository]）——PlanRepository 已是
/// plan/milestone/assessment 三表聚合根，再加 day_task 方法会膨胀。
/// 单独 repo 便于后续单独注入 provider / scenario。
class PlanDayTaskRepository {
  final StudyDatabase _db;
  PlanDayTaskRepository(this._db);

  /// 任意 DateTime → 本地零点 millis。归一化集中此处，避免各处散落写错。
  ///
  /// 选本地而非 UTC：用户对「今天/明天」的认知是本地日历，UTC 会让
  /// 跨时区用户在午夜后看到错位的任务队列。
  static int _toMillis(DateTime d) =>
      DateTime(d.year, d.month, d.day).millisecondsSinceEpoch;

  /// 加一条任务。调用方传入任意 DateTime，内部归一化到本地零点。
  Future<int> addTask(PlanDayTask t) =>
      _db.db.insert('plan_day_task', t.toMap());

  /// 查某 plan 某本地日历日的所有任务，按 sort_order, id 排。
  Future<List<PlanDayTask>> findByPlanAndDate(int planId, DateTime date) async {
    final start = _toMillis(date);
    final end = _toMillis(DateTime(date.year, date.month, date.day + 1));
    final rows = await _db.db.query(
      'plan_day_task',
      where: 'plan_id = ? AND task_date >= ? AND task_date < ?',
      whereArgs: [planId, start, end],
      orderBy: 'sort_order, id',
    );
    return rows.map(PlanDayTask.fromMap).toList();
  }

  /// 查某 plan 全部任务（日历视图用）。按 (task_date, sort_order) 排。
  Future<List<PlanDayTask>> findByPlan(int planId) async {
    final rows = await _db.db.query(
      'plan_day_task',
      where: 'plan_id = ?',
      whereArgs: [planId],
      orderBy: 'task_date, sort_order, id',
    );
    return rows.map(PlanDayTask.fromMap).toList();
  }

  /// 部分更新。仅传非 null 字段被改，并刷 updated_at。
  ///
  /// - status 置 'done' 且未传 doneAt 时，自动写当前时间；
  /// - status 退回 'pending' 时清空 done_at。
  Future<void> updateTask(
    int id, {
    String? title,
    DateTime? taskDate,
    int? sortOrder,
    String? status,
    DateTime? doneAt,
  }) async {
    final patch = <String, Object?>{
      if (title != null) 'title': title,
      if (taskDate != null) 'task_date': _toMillis(taskDate),
      if (sortOrder != null) 'sort_order': sortOrder,
      if (status != null) 'status': status,
      if (status == 'pending') 'done_at': null,
      if (status == 'done' && doneAt == null)
        'done_at': DateTime.now().millisecondsSinceEpoch,
      if (doneAt != null) 'done_at': doneAt.millisecondsSinceEpoch,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    };
    await _db.db.update('plan_day_task', patch, where: 'id = ?', whereArgs: [id]);
  }

  Future<void> deleteTask(int id) =>
      _db.db.delete('plan_day_task', where: 'id = ?', whereArgs: [id]);

  /// 统计某 plan 在 [from, to]（含两端，按本地日）的任务总数和已完成数。
  /// 返回 record 类型 `({int total, int done})`。
  Future<({int total, int done})> countDoneBetween(
    int planId,
    DateTime from,
    DateTime to,
  ) async {
    final startMs = _toMillis(from);
    final endMs = _toMillis(DateTime(to.year, to.month, to.day + 1));
    final rows = await _db.db.rawQuery(
      '''
      SELECT
        COUNT(*) AS total,
        SUM(CASE WHEN status = 'done' THEN 1 ELSE 0 END) AS done
      FROM plan_day_task
      WHERE plan_id = ? AND task_date >= ? AND task_date < ?
      ''',
      [planId, startMs, endMs],
    );
    final total = (rows.first['total'] as num).toInt();
    final done = (rows.first['done'] as num?)?.toInt() ?? 0;
    return (total: total, done: done);
  }
}