import 'package:study_engine/study_engine.dart';

/// DB 优先的 PromptResolver：用 [lookup]（App 层从 `prompt_override` 表预取的
/// 内存 Map）决定是否有覆盖；有覆盖用覆盖，无覆盖委托默认纯 Dart 模板。
///
/// 注意：PromptResolver.resolve 是同步接口，而 DB 读取是异步的——因此覆盖内容
/// 由调用方（agent_session_provider）在 run() 早期 await 预取，这里只做同步查表。
typedef PromptOverrideLookup = String? Function(String scenarioId);

class DbPromptResolver implements PromptResolver {
  final PromptOverrideLookup lookup;
  const DbPromptResolver(this.lookup);

  @override
  String resolve(String scenarioId, AgentScenarioContext ctx) {
    final override = lookup(scenarioId);
    if (override == null) {
      return const DefaultPromptResolver().resolve(scenarioId, ctx);
    }
    // 覆盖内容同样填占位符（today / plan_summary），保证动态信息不丢。
    return _fillPlaceholders(override, ctx);
  }

  String _fillPlaceholders(String template, AgentScenarioContext ctx) {
    final today = ctx.extra['today'] as DateTime?;
    final todayStr = today != null
        ? '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}'
        : '（未知）';
    final planSummary =
        ctx.extra['plan_summary'] as String? ?? '（无当前计划，用户可能要新建）';
    return template
        .replaceAll('{{today}}', todayStr)
        .replaceAll('{{plan_summary}}', planSummary);
  }
}
