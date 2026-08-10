import '../models/models.dart';

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
