/// 工具执行上下文：execute 时透传给实现的附加信息。
///
/// [scenarioContext] 为 Object?（具体类型由场景实现自行 cast），避免
/// tool_definition 与 agent_scenario 互相 import 形成循环。
class ToolExecContext {
  final String? toolCallId;
  final Object? scenarioContext;
  final void Function(String)? onProgress;
  const ToolExecContext({this.toolCallId, this.scenarioContext, this.onProgress});
}

/// 工具抽象（opencode registry 思路）：把「LLM 看到的 schema」与「引擎执行的
/// 逻辑」统一成一份定义。场景通过 [definitions] 暴露全部工具，
/// [AgentScenario.executeTool] 按 id 查表分发。
///
/// 预留扩展点：将来接 MCP server（读 tools/list 动态注册）时，只需新增
/// 一个 ToolDefinition 的注册源，无需改动场景的 execute 分发。
abstract class ToolDefinition {
  String get id;
  String get description;
  Map<String, dynamic> get parameters;
  Future<String> execute(Map<String, dynamic> args, ToolExecContext ctx);
}

/// 基于现有 const schema Map（OpenAI function calling）的 ToolDefinition 实现：
/// schema 提供 id/description/parameters（零重写），execute 由闭包提供
/// （复用场景里的私有实现方法）。
class SchemaToolDefinition implements ToolDefinition {
  final Map<String, dynamic> schema;
  final Future<String> Function(Map<String, dynamic> args, ToolExecContext ctx) exec;

  SchemaToolDefinition(this.schema, this.exec);

  @override
  String get id => (schema['function'] as Map)['name'] as String;

  @override
  String get description =>
      (schema['function'] as Map)['description'] as String;

  @override
  Map<String, dynamic> get parameters =>
      (schema['function'] as Map)['parameters'] as Map<String, dynamic>;

  @override
  Future<String> execute(Map<String, dynamic> args, ToolExecContext ctx) =>
      exec(args, ctx);
}
