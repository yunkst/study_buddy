import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:study_engine/study_engine.dart';

import '../services/llm_logger/llm_logger.dart';
import '../services/logger_service.dart';
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

/// APP 层计划 agent 调用入口：构造 PlanScenario + AgentLoop，注入当前 plan 概要与日期。
///
/// 取 vision:false 默认 LlmConfig（计划场景不需要视觉）。
class PlanSession {
  PlanSession(this._ref);
  final Ref _ref;

  /// 运行计划 agent。planId 为空时是"新建模式"，非空时注入该计划概要到 system prompt。
  /// 返回会话句柄，UI 监听 handle.stream 并可在 AskUserRequestedEvent 后回灌答案。
  Future<AgentSessionHandle> run(
    List<ChatMessage> messages, {
    int? planId,
    required DateTime today,
  }) async {
    final db = await _ref.read(databaseProvider.future);
    final llmConfigs = LlmConfigRepository(db);
    final cfg = await llmConfigs.getDefault(vision: false);
    if (cfg == null) {
      throw StateError(
        '未配置默认 LLM。请先在 llm_config 表中添加 is_default=1 的记录。',
      );
    }
    final plans = PlanRepository(db);
    final memories = AgentMemoryRepository(db);
    final dayTasks = PlanDayTaskRepository(db);

    String planSummary;
    if (planId != null) {
      final detail = await plans.getPlanDetail(planId);
      final msBlock = detail.milestones.map((m) => '- ${m.targetDate.year}-${m.targetDate.month.toString().padLeft(2, '0')}-${m.targetDate.day.toString().padLeft(2, '0')} ${m.title} [${m.status}]').join('\n');
      final lastA = detail.assessments.isNotEmpty ? detail.assessments.last : null;
      planSummary = '计划：${detail.plan.name}（id=${detail.plan.id}）\n'
          '考试：${detail.plan.examDate.year}-${detail.plan.examDate.month.toString().padLeft(2, '0')}-${detail.plan.examDate.day.toString().padLeft(2, '0')}，目标：${detail.plan.target}\n'
          '每日时长：${detail.plan.dailyMinutes} 分钟\n'
          '节点：\n$msBlock\n'
          '最近测评：${lastA?.score ?? "无"}${lastA?.note != null ? "（${lastA!.note}）" : ""}';
    } else {
      planSummary = '（用户尚未指定计划，可能是新建场景。请收齐信息后 create_plan。）';
    }

    final llm = LlmProvider(
      config: cfg,
      llmSink: LlmLogger.instance,
      logger: LoggerService.instance,
    );
    final scenario = PlanScenario(plans: plans, memories: memories, dayTasks: dayTasks);
    final ctx = AgentScenarioContext(extra: {
      'today': today,
      'plan_summary': planSummary,
    });
    // system prompt 由 AgentLoop 自动注入(见 agent_loop.dart:24 注释)：
    // 检测到 messages 无 system 时调 scenario.buildSystemPrompt(ctx) 并补 getMemories()。
    // 故调用方只需传 ctx，无需自前置 system(否则会跳过记忆填充)。
    final traceId = 'plan-${DateTime.now().millisecondsSinceEpoch}';
    final loop = AgentLoop(llm: llm, scenario: scenario, logger: LoggerService.instance);
    LoggerService.instance.i(
      '计划会话开始',
      category: LogCategory.ai,
      tags: const ['session-start'],
      traceId: traceId,
    );
    return AgentSessionHandle(
      stream: loop.run(messages, context: ctx, traceId: traceId),
      completeAskUser: loop.completeAskUser,
      abortAskUser: loop.abortAskUser,
    );
  }
}

final planSessionProvider = Provider<PlanSession>((ref) {
  return PlanSession(ref);
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
