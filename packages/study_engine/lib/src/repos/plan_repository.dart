import '../db/database.dart';
import '../models/plan_models.dart';

/// 计划详情聚合：Plan + 节点列表 + 测评列表。
class PlanDetail {
  final Plan plan;
  final List<Milestone> milestones;
  final List<Assessment> assessments;
  PlanDetail(this.plan, this.milestones, this.assessments);
}

class PlanRepository {
  final StudyDatabase _db;
  PlanRepository(this._db);

  // ===== Plan =====
  Future<int> insertPlan(Plan p) => _db.db.insert('plan', p.toMap());

  Future<Plan?> findPlanById(int id) async {
    final rows = await _db.db.query('plan', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : Plan.fromMap(rows.first);
  }

  Future<List<Plan>> findAllPlans() async {
    final rows = await _db.db.query('plan', orderBy: 'updated_at DESC');
    return rows.map(Plan.fromMap).toList();
  }

  /// 更新计划元信息并刷新 updated_at。
  Future<void> updatePlan(Plan p) async {
    await _db.db.update(
      'plan',
      Plan(
        id: p.id, name: p.name, examDate: p.examDate, examContent: p.examContent,
        target: p.target, dailyMinutes: p.dailyMinutes, currentLevel: p.currentLevel,
        createdAt: p.createdAt, updatedAt: DateTime.now(),
      ).toMap(),
      where: 'id = ?', whereArgs: [p.id],
    );
  }

  Future<void> deletePlan(int id) => _db.db.delete('plan', where: 'id = ?', whereArgs: [id]);

  // ===== Milestone =====
  Future<int> addMilestone(Milestone m) => _db.db.insert('milestone', m.toMap());

  Future<List<Milestone>> findMilestonesByPlan(int planId) async {
    final rows = await _db.db.query('milestone', where: 'plan_id = ?', whereArgs: [planId], orderBy: 'sort_order, target_date');
    return rows.map(Milestone.fromMap).toList();
  }

  /// 部分更新节点。仅传非 null 字段被改，并刷 updated_at。
  Future<void> updateMilestone(
    int id, {
    String? title,
    String? description,
    DateTime? targetDate,
    int? sortOrder,
    String? status,
  }) async {
    final patch = <String, Object?>{
      if (title != null) 'title': title,
      if (description != null) 'description': description,
      if (targetDate != null) 'target_date': targetDate.millisecondsSinceEpoch,
      if (sortOrder != null) 'sort_order': sortOrder,
      if (status != null) 'status': status,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    };
    await _db.db.update('milestone', patch, where: 'id = ?', whereArgs: [id]);
  }

  Future<void> deleteMilestone(int id) => _db.db.delete('milestone', where: 'id = ?', whereArgs: [id]);

  // ===== Assessment =====
  Future<int> addAssessment(Assessment a) => _db.db.insert('assessment', a.toMap());

  Future<List<Assessment>> findAssessmentsByPlan(int planId) async {
    final rows = await _db.db.query('assessment', where: 'plan_id = ?', whereArgs: [planId], orderBy: 'assessed_at');
    return rows.map(Assessment.fromMap).toList();
  }

  /// 最近一次测评（按 assessed_at 降序取首条）。无测评返回 null。
  Future<Assessment?> latestAssessment(int planId) async {
    final rows = await _db.db.query('assessment', where: 'plan_id = ?', whereArgs: [planId], orderBy: 'assessed_at DESC', limit: 1);
    return rows.isEmpty ? null : Assessment.fromMap(rows.first);
  }

  // ===== 聚合 =====
  Future<PlanDetail> getPlanDetail(int planId) async {
    final plan = await findPlanById(planId);
    if (plan == null) throw StateError('计划 id=$planId 不存在');
    final milestones = await findMilestonesByPlan(planId);
    final assessments = await findAssessmentsByPlan(planId);
    return PlanDetail(plan, milestones, assessments);
  }
}
