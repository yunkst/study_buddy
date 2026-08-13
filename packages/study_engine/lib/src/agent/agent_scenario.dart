import '../models/models.dart';
import 'tool_definition.dart';

/// 场景上下文：注入每轮动态信息（当前学科、最近拍题结果等）。
class AgentScenarioContext {
  final String? currentSubject;
  final Map<String, Object?> extra;
  const AgentScenarioContext({this.currentSubject, this.extra = const {}});
}

/// patch_memory 工具的结果。
class MemoryPatchResult {
  final bool ok;
  final String message; // 成功提示或编号越界时的可用编号列表
  MemoryPatchResult(this.ok, this.message);
}

/// Agent 场景抽象：每个场景自带工具集、系统提示词、工具执行、记忆。
abstract class AgentScenario {
  String get id;
  String get displayName;
  List<Map<String, dynamic>> get tools;
  String buildSystemPrompt(AgentScenarioContext ctx);

  /// 工具定义表（id → schema + execute）。默认空——无工具场景（及测试 fake）
  /// 无需实现；场景通过注册 [ToolDefinition] 让 [executeTool] 按 id 查表分发。
  List<ToolDefinition> get definitions => const [];

  /// 构造「发给 LLM 的消息列表」（hermes compose_user_api_content 思路）。
  ///
  /// 返回新列表（不改 [base]），AgentLoop 在注入 system prompt 后调用一次。
  /// 场景实现可对"当前轮用户消息"（base 里 role==user 的最后一条）stamp
  /// ChatMessage.apiContent——把记忆/上下文等瞬时注入拼到 API 副本上，
  /// 而 [base] 里的 content 保持干净（存储/UI 用）。
  /// 默认实现原样返回，无注入场景（及测试 fake）无需实现。
  List<ChatMessage> composeApiMessages(List<ChatMessage> base, AgentScenarioContext ctx) =>
      base;

  /// 执行工具，返回给 LLM 的文本结果。
  Future<String> executeTool(
    String name,
    Map<String, dynamic> args, {
    void Function(String)? onProgress,
    String? toolCallId,
    AgentScenarioContext? context,
  });

  /// 无工具调用时的钩子；返回非 null 则作为额外提示再走一轮。
  Future<String?> onNoToolCalls(List<ChatMessage> messages);

  Future<List<String>> getMemories();
  Future<MemoryPatchResult> patchMemory(int? index, String newText);
  Future<void> cleanup();
}
