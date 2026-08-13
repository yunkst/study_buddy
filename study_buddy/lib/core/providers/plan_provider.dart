import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:study_engine/study_engine.dart';

import 'database_provider.dart';

/// 异步获取 PlanRepository（等待 db 就绪）。
final planRepositoryAsyncProvider = FutureProvider<PlanRepository>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  return PlanRepository(db);
});

/// 计划列表（首页用）。
final planListProvider = FutureProvider<List<Plan>>((ref) async {
  final repo = await ref.watch(planRepositoryAsyncProvider.future);
  return repo.findAllPlans();
});

/// 计划详情聚合（详情页用）。
final planDetailProvider = FutureProvider.family<PlanDetail, int>((ref, planId) async {
  final repo = await ref.watch(planRepositoryAsyncProvider.future);
  return repo.getPlanDetail(planId);
});

/// 计划每日任务仓储 provider（日历视图用）。
final planDayTaskRepositoryAsyncProvider =
    FutureProvider<PlanDayTaskRepository>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  return PlanDayTaskRepository(db);
});

/// 某 plan 全部每日任务（family 参数 planId）。日历视图与详情页共用。
final planDayTasksProvider =
    FutureProvider.family<List<PlanDayTask>, int>((ref, planId) async {
  final repo = await ref.watch(planDayTaskRepositoryAsyncProvider.future);
  return repo.findByPlan(planId);
});
