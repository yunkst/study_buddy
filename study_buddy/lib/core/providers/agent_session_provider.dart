import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:study_engine/study_engine.dart';

import 'database_provider.dart';

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
  /// [context] 注入场景动态信息（如当前知识点），由 AgentLoop 透传给
  /// `buildSystemPrompt`。既有调用方（如 ai_panel_sheet）不传 context，
  /// 走默认空上下文，行为不变。
  Future<Stream<AgentEvent>> run(
    List<ChatMessage> messages, {
    AgentScenarioContext? context,
  }) async {
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

    final llm = LlmProvider(config: cfg);
    final scenario = StudyScenario(
      categories: categories,
      topics: topics,
      edges: edgesRepo,
      memories: memories,
    );
    final loop = AgentLoop(llm: llm, scenario: scenario);
    return loop.run(messages, context: context);
  }
}

final agentSessionProvider = Provider<AgentSession>((ref) {
  return AgentSession(ref);
});
