import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:study_engine/study_engine.dart';

import '../services/llm_logger/llm_logger.dart';
import '../services/logger_service.dart';
import 'llm_config_provider.dart';

/// AI 生成的「今日学习收获」总结，用于分享卡「今日收获」区 + 复制到剪贴板的正文。
///
/// **触发时机**：按需在用户点分享时生成（autoDispose.family(topics)），
/// 不进页预生成——节省 token，用户未必真分享。
///
/// **输入素材**：今日学过的知识点标题列表 + 总专注分钟数（用户确认）。
///
/// **降级**（任一即返回模板文案，不抛错，不阻断分享流程）：
/// - 未配置 LLM（llmConfigProvider 为 null）或 apiKey 为空
/// - 调用失败（LlmHttpException / 网络错）
/// - 模型返回空文本
/// - 今日没有任何知识点（空输入）
///
/// 用 family 以知识点列表为 key，autoDispose 在卡片关闭后释放；
/// 同一列表复用结果。
final dailySummaryProvider =
    FutureProvider.autoDispose.family<String, List<Topic>>((ref, topics) async {
  final titles = topics
      .map((t) => t.title)
      .where((s) => s.trim().isNotEmpty)
      .toList(growable: false);

  // 空输入：不强造 AI 文案，直接鼓励模板。
  if (titles.isEmpty) {
    return _templateForEmpty();
  }

  final cfg = await ref.watch(llmConfigProvider.future);
  // 无 key / 未配置 → 模板降级。
  if (cfg == null || cfg.apiKey.isEmpty || cfg.model.isEmpty) {
    return _templateSummary(titles);
  }

  final traceId = 'share-summary-${DateTime.now().millisecondsSinceEpoch}';
  final llm = LlmProvider(
    config: cfg,
    llmSink: LlmLogger.instance,
    logger: LoggerService.instance,
  );
  try {
    final text = await completeText(
      llm,
      system: _systemPrompt,
      user: _userPrompt(titles),
      traceId: traceId,
    );
    return text.isEmpty ? _templateSummary(titles) : text;
  } catch (e) {
    // 任何 LLM/网络错都降级到模板，不阻断分享。
    LoggerService.instance
        .w('今日总结 AI 生成失败，降级模板: $e', category: LogCategory.ai, tags: const ['share-summary']);
    return _templateSummary(titles);
  }
});

/// System prompt：强约束长度、口吻、格式，避免跑题/超长/markdown 堆砌。
const _systemPrompt = '你是学习打卡助手。根据用户今天复习的知识点，'
    '写一句（不超过40字）适合发小红书学习打卡的收获总结。'
    '要求：口语化、第二人称视角、有成就感；只能用提供的知识点名称，不要编造；'
    '不要 markdown、不要列表、不要堆砌 emoji（最多1个）；直接输出总结正文，不要前缀。';

String _userPrompt(List<String> titles) {
  return '今天复习了这些知识点：${titles.join("、")}。请写一句收获总结。';
}

/// 模板降级文案（AI 不可用时）：用真实知识点标题，口语化。
String _templateSummary(List<String> titles) {
  final sample = titles.length <= 3 ? titles.join('、') : '${titles.take(3).join("、")} 等';
  return '今天啃下了 $sample，又进步一点点！';
}

String _templateForEmpty() => '今天先迈出学习第一步吧，哪怕五分钟也算赢！';
