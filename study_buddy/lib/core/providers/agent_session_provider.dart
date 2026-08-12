import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:study_engine/study_engine.dart';

import '../services/llm_logger/llm_logger.dart';
import '../services/logger_service.dart';
import 'database_provider.dart';
import 'focus_session_provider.dart';

/// APP 层 agent 调用入口：构造 StudyScenario + AgentLoop 并返回事件流。
///
/// 该 provider 故意不在内部持有 LlmProvider 实例（每次 run() 重新构造，
/// 因为 LlmConfig 可能被用户在线程外修改）。LLM 配置取自 `llm_config`
/// 表的默认 vision 配置；若不存在默认项，run() 会抛错并由 UI 层捕获。
class AgentSession {
  AgentSession(this._ref);

  final Ref _ref;

  /// 运行 agent 循环。返回 [AgentEvent] 事件流（实时增量）。
  ///
  /// 每次调用都会重新从 DB 读取 LLM 配置、构造新的 StudyScenario 与 AgentLoop。
  /// 调用方负责监听流并在 done/error 时释放资源。
  ///
  /// [chatSessionId] 可选：传入则注入 AgentScenarioContext.extra，供 save_review
  /// 等工具把批改明细落库到对应会话；不传则 chatSessionId 为 null。
  Future<Stream<AgentEvent>> run(List<ChatMessage> messages, {int? chatSessionId}) async {
    final db = await _ref.read(databaseProvider.future);
    final llmConfigs = LlmConfigRepository(db);
    final cfg = await llmConfigs.getDefault(vision: true);
    if (cfg == null) {
      throw StateError(
        '未配置支持视觉的默认 LLM。请先在 llm_config 表中添加 '
        'is_default=1 且 supports_vision=1 的记录。',
      );
    }
    final categories = CategoryRepository(db);
    final topics = TopicRepository(db);
    final edgesRepo = TopicEdgeRepository(db);
    final memories = AgentMemoryRepository(db);

    final traceId = 'agent-${DateTime.now().millisecondsSinceEpoch}';
    final llm = LlmProvider(
      config: cfg,
      llmSink: LlmLogger.instance,
      logger: LoggerService.instance,
    );
    final scenario = StudyScenario(
      categories: categories,
      topics: topics,
      edges: edgesRepo,
      memories: memories,
      mastery: MasteryRepository(db),
      reviews: ReviewRepository(db),
      schedules: TopicScheduleRepository(db),
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
    return loop.run(
      messages,
      context: AgentScenarioContext(extra: chatSessionId == null ? const {} : {'chat_session_id': chatSessionId}),
      traceId: traceId,
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
