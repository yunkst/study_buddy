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
    final topicContext = ctx.extra['topic_context'] as String? ?? '';
    // 知识点教学模式段：仅在 topic_context 非空（详情页【为什么？】入口）时激活，
    // 让 AI 从知识点诞生的场景/解决的问题出发做启发式教学，而非一上来给定义。
    final teachingBlock = topicContext.isEmpty
        ? ''
        : '''
## 知识点教学模式（当提供「当前知识点上下文」时激活）
$topicContext

用户从「为什么」入口学习这一个知识点。目标：让他先理解这个知识点诞生的原因和它解决的问题，而不是一上来记定义。
要求：
1. 第一轮开场：先讲一个具体的场景——这个知识点当初是为了解决什么问题/什么困境而诞生的（历史背景、现实问题或典型应用均可）。用场景引入，不要一上来给定义公式。
2. 从场景出发，解释它解决了什么、核心思想是什么。
3. 讲完场景和动机后，再逐步引导用户理解核心内容，一次只讲一步，多用提问确认他懂了没，不一次性倒出全部内容。
4. 用户切换请求（批改/计划/分析题目）时，回到对应流程。

''';
    return kStudyPlanSystemPromptTemplate
        .replaceAll('{{today}}', todayStr)
        .replaceAll('{{plan_summary}}', planSummary)
        .replaceAll('{{topic_context}}', teachingBlock);
  }
}
