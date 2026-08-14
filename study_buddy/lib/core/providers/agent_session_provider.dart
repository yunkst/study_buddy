import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:study_engine/study_engine.dart';

import '../services/llm_logger/llm_logger.dart';
import '../services/logger_service.dart';
import '../services/prompt_resolver_db.dart';
import 'database_provider.dart';
import 'focus_session_provider.dart';
import 'topic_schedule_provider.dart';
import '../../features/knowledge/knowledge_providers.dart';

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
  ///
  /// [topicId] 可选：非空则读取该知识点（标题/分类路径/引子/答案）到 system prompt，
  /// 触发「知识点教学模式」（详情页【为什么？】入口）；为空时是普通学习伴侣会话。
  Future<AgentSessionHandle> run(
    List<ChatMessage> messages, {
    int? chatSessionId,
    int? planId,
    DateTime? today,
    int? topicId,
  }) async {
    final db = await _ref.read(databaseProvider.future);
    final cfg = await _defaultLlmConfig(db);
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

    // 知识点教学模式上下文：仿 planSummary 从 DB 读 Topic + 分类路径拼成文本，
    // 供 PromptResolver 渲染「知识点教学模式」段（空串则不激活教学模式）。
    String topicContext = '';
    if (topicId != null) {
      final t = await topics.findById(topicId);
      if (t != null) {
        final path = (await categories.pathOf(t.categoryId)).join('/');
        topicContext = '知识点：${t.title}（id=${t.id}）\n'
            '分类路径：$path\n'
            '引子（背景/问题）：${t.question}\n'
            '答案（核心内容）：${t.summary}';
      } else {
        topicContext = '（知识点 id=$topicId 不存在）';
      }
    }

    final traceId = 'agent-${DateTime.now().millisecondsSinceEpoch}';
    final llm = LlmProvider(
      config: cfg,
      llmSink: LlmLogger.instance,
      logger: LoggerService.instance,
    );
    // system prompt 覆盖预取：DbPromptResolver 需要同步查表，故在 async run 里
    // 先读 `prompt_override` 表到内存 Map（无覆盖则走引擎默认模板）。
    final overrides = await _loadPromptOverrides(db);
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
      promptResolver: DbPromptResolver((sid) => overrides[sid]),
      onTopicTouched: (topicId) async {
        // agent 写库（save_topic/update_topic 等）后作废知识 Tab 缓存，
        // 否则已浏览过知识页的用户切回看不到新增知识点。
        invalidateKnowledgeCache(_ref.container);
        // 仅专注会话进行中才关联；非专注期 no-op
        final sessionId = _ref.read(focusSessionProvider).sessionId;
        if (sessionId != null) {
          final focusRepo = FocusSessionRepository(db);
          await focusRepo.linkTopic(sessionId, topicId);
        }
        // 新知识点已入 FSRS 队列（_saveTopic 建默认 schedule 行），立即刷新
        // 今日待复习数。reviewQueueProvider 是 autoDispose，下次进入复习页自动重查。
        _ref.invalidate(dueNowCountProvider);
      },
    );
    final loop = AgentLoop(
      llm: llm,
      scenario: scenario,
      logger: LoggerService.instance,
      // 上下文压缩：丢弃中间轮次前用 LLM 摘要回填（代替纯硬截断），避免长对话失忆。
      compactor: ContextCompactor(
        summarize: (dropped) => _summarizeDropped(llm, dropped),
      ),
      // 超长工具输出落临时文件（opencode 风格），保留可追溯指针。
      toolTmpDir: (await _resolveTmpDir())?.path,
    );
    LoggerService.instance.i('Agent 会话开始', category: LogCategory.ai, tags: const ['session-start'], traceId: traceId);
    return AgentSessionHandle(
      stream: loop.run(
        messages,
        context: AgentScenarioContext(extra: {
          'today': today ?? DateTime.now(),
          'plan_summary': planSummary,
          if (chatSessionId != null) 'chat_session_id': chatSessionId,
          if (topicContext.isNotEmpty) 'topic_context': topicContext,
        }),
        traceId: traceId,
      ),
      completeAskUser: loop.completeAskUser,
      abortAskUser: loop.abortAskUser,
    );
  }

  /// 读取默认 LLM 配置（vision 优先，回退普通默认项）。无配置返回 null。
  /// run() 与 distillMemory() 共用，避免两处重复解析逻辑。
  Future<LlmConfig?> _defaultLlmConfig(StudyDatabase db) async {
    final llmConfigs = LlmConfigRepository(db);
    return await llmConfigs.getDefault(vision: true) ??
        await llmConfigs.getDefault(vision: false);
  }

  /// 沉淀经验记忆（P2）：用户点击「新对话」时调用，把本次对话提炼成记忆写入。
  /// fire-and-forget：调用方不 await；内部任何失败都不抛出（Distiller 兜底 + 本方法再兜一层），
  /// 绝不影响新对话体验。未配置 LLM 时静默跳过。
  Future<void> distillMemory(List<ChatMessage> messages, {String? traceId}) async {
    try {
      final db = await _ref.read(databaseProvider.future);
      final cfg = await _defaultLlmConfig(db);
      if (cfg == null) return; // 未配置 LLM：静默跳过
      final llm = LlmProvider(
        config: cfg,
        llmSink: LlmLogger.instance,
        logger: LoggerService.instance,
      );
      final distiller = MemoryDistiller(
        llm: llm,
        memories: AgentMemoryRepository(db),
        logger: LoggerService.instance,
      );
      await distiller.distill(
        messages: messages,
        scenarioId: 'study_plan',
        traceId: traceId ?? 'distill-${DateTime.now().millisecondsSinceEpoch}',
      );
    } catch (e) {
      // App 层日志便捷方法（e/log 同语义）：sink 接口 log() 的 category 是 String，
      // 而 LogCategory.ai 是 App 层枚举，二者不可混用（analyze 会报类型错）。
      LoggerService.instance.e('记忆沉淀失败: $e',
          category: LogCategory.ai, tags: const ['memory']);
    }
  }

  /// 预取所有场景的 system prompt 覆盖（scenario_id → content）。
  /// 无覆盖的返回空 Map（走引擎默认模板）。设置页编辑后下次 run() 自动生效。
  Future<Map<String, String>> _loadPromptOverrides(StudyDatabase db) async {
    final repo = PromptOverrideRepository(db);
    final result = <String, String>{};
    for (final sid in const ['study_plan']) {
      final content = await repo.get(sid);
      if (content != null) result[sid] = content;
    }
    return result;
  }

  static Directory? _tmpDirCache;

  /// 系统临时目录（超长工具输出落盘用）。获取失败返回 null（不截断）。
  Future<Directory?> _resolveTmpDir() async {
    final cached = _tmpDirCache;
    if (cached != null) return cached;
    try {
      _tmpDirCache = await getTemporaryDirectory();
    } catch (_) {
      _tmpDirCache = null;
    }
    return _tmpDirCache;
  }

  /// 把被压缩丢弃的中间轮次摘要成一条 system 消息（LLM 调用）。
  /// 抛错由 [ContextCompactor.compactAsync] 捕获并 fallback 硬截断。
  Future<ChatMessage> _summarizeDropped(LlmProvider llm, List<ChatMessage> dropped) async {
    final text = await completeText(
      llm,
      system: '你是对话压缩助手。把用户与学习伴侣 AI 的较早对话压缩成中文摘要，'
          '保留关键结论与数据：创建/更新的知识点 id 与标题、计划/节点/任务的 id、'
          '掌握度判定、批改结果。不要编造，输出 3-5 句。',
      user: '以下是较早轮次（将被压缩掉）:\n\n${_renderDropped(dropped)}',
    );
    return ChatMessage(role: 'system', content: '【对话历史摘要】$text');
  }

  /// 消息列表 → 压缩输入文本（content 兼容 String 与 vision parts）。
  String _renderDropped(List<ChatMessage> msgs) {
    final buf = StringBuffer();
    for (final m in msgs) {
      final content = switch (m.content) {
        String s => s,
        List<ContentPart> parts =>
          parts.whereType<TextPart>().map((p) => p.text).join('\n'),
        _ => '',
      };
      if (m.toolCalls != null) {
        final calls = m.toolCalls!.map((t) => '${t.name}(${t.arguments})').join('; ');
        buf.writeln('[assistant tool_calls] $calls');
      } else if (m.toolCallId != null) {
        buf.writeln('[tool result ${m.toolCallId}] $content');
      } else {
        buf.writeln('[${m.role}] $content');
      }
    }
    return buf.toString();
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
