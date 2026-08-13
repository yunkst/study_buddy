import '../models/models.dart';
import 'llm_provider_core.dart';

/// 一次性文本补全入口：把流式响应 [LlmProvider.chatStreamWithTools] 收集成整段文本。
///
/// 引擎目前只有流式对话（SSE），本项目尚未有「一段 prompt 换一段文本」的同步入口。
/// 此处封装 `tools: []`（纯聊天、无工具）场景，供上层（如分享卡「今日收获」AI 总结）
/// 不直接接触流处理：`await for` 拼 [LlmStreamChunk.textDelta]，去掉末包（textDelta 为空）。
///
/// 抛错语义沿用 [LlmProvider]（`LlmHttpException` / 网络异常），调用方自行 try/catch 兜底。
/// 返回空串表示模型未产出文本（流结束前可能也什么都没给）。
Future<String> completeText(
  LlmProvider llm, {
  required String system,
  required String user,
  String? traceId,
}) async {
  final messages = [
    ChatMessage(role: 'system', content: system),
    ChatMessage(role: 'user', content: user),
  ];
  final buffer = StringBuffer();
  await for (final chunk
      in llm.chatStreamWithTools(messages: messages, tools: [], traceId: traceId)) {
    if (chunk.textDelta.isNotEmpty) buffer.write(chunk.textDelta);
  }
  return buffer.toString().trim();
}