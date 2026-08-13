import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:study_engine/study_engine.dart';

import '../services/llm_logger/llm_logger.dart';
import '../services/logger_service.dart';
import 'database_provider.dart';
import 'focus_session_provider.dart';

/// APP 层 agent 调用入口：构造 StudyPlanScenario + AgentLoop 并返回事件流。
///
/// 统一承载 chat（拍照批改/知识库）与 plan（学习计划）两种会话：chat 走
/// [chatSessionId]，计划走 [planId]+[today]。该 provider 故意不在内部持有
/// LlmProvider 实例（每次 run() 重新构造，因为 LlmConfig 可能被用户在线程外
/// 修改）。LLM 配置取自 `llm_config` 表的默认项：优先 supports_vision 的默认项
/// （chat 拍照必需），无视觉项时回退普通默认项（计划对话可无图）；均无则抛错。
class AgentSession {
  AgentSession(this._ref);

  final Ref _ref;

  /// 运行 agent 循环。返回会话句柄（含事件流，供 UI 监听并回灌 ask_user 答案）。
  ///
  /// 每次调用都会重新从 DB 读取 LLM 配置、构造新的 StudyPlanScenario 与 AgentLoop。
  /// 调用方负责监听 handle.stream 并在 done/error 时释放资源。
  ///
  /// [chatSessionId] 可选：传入则注入 AgentScenarioContext.extra，供 save_review
  /// 等工具把批改明细落库到对应会话；不传则 chatSessionId 为 null。
  ///
  /// [planId] 可选：非空则读取该计划概要到 system prompt（调整模式）；为空时
  /// 是"新建计划"模式（提示词会引导收齐信息后 create_plan）。[today] 可选：
  /// 总是注入今天日期，供 agent 推算相对时间（不传默认 DateTime.now()）。
  Future<AgentSessionHandle> run(
    List<ChatMessage> messages, {
    int? chatSessionId,
    int? planId,
    DateTime? today,
  }) async {
    final db = await _ref.read(databaseProvider.future);
    final llmConfigs = LlmConfigRepository(db);
    // 主入口（拍照批改）必须视觉，故 vision 优先；计划对话可无图，回退普通默认项。
    final cfg = await llmConfigs.getDefault(vision: true) ??
        await llmConfigs.getDefault(vision: false);
    if (cfg == null) {
      throw StateError(
        '未配置默认 LLM。请先在 llm_config 表中添加 is_default=1 的记录。',
      );
    }
    final categories = CategoryRepository(db);
    final topics = TopicRepository(db);
    final edgesRepo = TopicEdgeRepository(db);
    final memories = AgentMemoryRepository(db);
    final plans = PlanRepository(db);
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

    final traceId = 'agent-${DateTime.now().millisecondsSinceEpoch}';
    final llm = LlmProvider(
      config: cfg,
      llmSink: LlmLogger.instance,
      logger: LoggerService.instance,
    );
    final scenario = StudyPlanScenario(
      categories: categories,
      topics: topics,
      edges: edgesRepo,
      memories: memories,
      mastery: MasteryRepository(db),
      reviews: ReviewRepository(db),
      schedules: TopicScheduleRepository(db),
      plans: plans,
      dayTasks: dayTasks,
      onTopicTouched: (topicId) async {
        // 仅专注会话进行中才关联；非专注期 no-op
        final sessionId = _ref.read(focusSessionProvider).sessionId;
        if (sessionId == null) return;
        final focusRepo = FocusSessionRepository(db);
        await focusRepo.linkTopic(sessionId, topicId);
      },
    );
    final loop = AgentLoop(llm: llm, scenario: scenario, logger: LoggerService.instance);
    LoggerService.instance.i('Agent 会话开始', category: LogCategory.ai, tags: const ['session-start'], traceId: traceId);
    return AgentSessionHandle(
      stream: loop.run(
        messages,
        context: AgentScenarioContext(extra: {
          'today': today ?? DateTime.now(),
          'plan_summary': planSummary,
          if (chatSessionId != null) 'chat_session_id': chatSessionId,
        }),
        traceId: traceId,
      ),
      completeAskUser: loop.completeAskUser,
      abortAskUser: loop.abortAskUser,
    );
  }
}

final agentSessionProvider = Provider<AgentSession>((ref) {
  return AgentSession(ref);
});

/// 批改仓库提供者:详情页查库用(await 打开数据库后构造 ReviewRepository)。
final reviewRepositoryProvider = FutureProvider<ReviewRepository>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  return ReviewRepository(db);
});
