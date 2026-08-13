import 'agent_scenario.dart';
import 'prompts/study_plan_prompt.dart';

/// System prompt 解析器：决定某场景最终发给 LLM 的 system prompt 文本。
///
/// 解耦「prompt 来源」与「场景逻辑」：基线模板在引擎（Dart 常量，可纯 Dart 测试），
/// App 层可用 [DbPromptResolver] 读 `prompt_override` 表做运行时覆盖（不发版即可调 prompt）。
abstract class PromptResolver {
  /// 返回该场景填好占位符后的完整 system prompt。
  String resolve(String scenarioId, AgentScenarioContext ctx);
}

/// 默认解析器：纯 Dart，按 scenarioId 取常量模板并替换占位符。
///
/// 默认实现按 plan_summary / today 等字段插值；新场景在此分支扩展即可。
/// 注意：**绝不读 DB**——system_prompt_test 在纯 Dart（无 DB）依赖此行为。
class DefaultPromptResolver implements PromptResolver {
  const DefaultPromptResolver();

  @override
  String resolve(String scenarioId, AgentScenarioContext ctx) {
    switch (scenarioId) {
      case 'study_plan':
        return _fillStudyPlan(ctx);
      default:
        throw ArgumentError('未知 scenarioId: $scenarioId');
    }
  }

  String _fillStudyPlan(AgentScenarioContext ctx) {
    final today = ctx.extra['today'] as DateTime?;
    final todayStr = today != null
        ? '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}'
        : '（未知）';
    final planSummary =
        ctx.extra['plan_summary'] as String? ?? '（无当前计划，用户可能要新建）';
    return kStudyPlanSystemPromptTemplate
        .replaceAll('{{today}}', todayStr)
        .replaceAll('{{plan_summary}}', planSummary);
  }
}
