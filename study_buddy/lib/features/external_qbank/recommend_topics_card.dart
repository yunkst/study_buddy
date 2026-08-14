// AI 推荐相关知识点返回的可点击卡片列表。
//
// recommend_topics 工具（只读检索）的结果由渲染器解析成 [RecommendTopicsItem] 列表，
// 交 [RecommendTopicsCard] 渲染：标题行 + 逐条目录行（标题 + 分类路径 + 掌握度标签），
// 点按进 `/topic/$id` 详情页。掌握度标签语义与 save_topic 的 SavedTopicCapsule 一致。
//
// 纸感风格对齐 saved_topic_capsule.dart：全走 theme.colorScheme / paper 扩展，
// 禁硬编码 Colors.*/Color(0x...)。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:study_engine/study_engine.dart';

import '../../core/theme/paper_extension.dart';
import '../knowledge/knowledge_providers.dart';

/// recommend_topics 工具返回的单条知识点。
class RecommendTopicsItem {
  final int id;
  final String title;
  final String path; // 分类路径,如 "数学/高等数学"
  const RecommendTopicsItem({
    required this.id,
    required this.title,
    required this.path,
  });
}

/// 掌握度标签文案（同步 SavedTopicCapsule 的语义）。
const Map<MasteryStatus, String> _masteryLabel = {
  MasteryStatus.mastered: '已掌握',
  MasteryStatus.learning: '学习中',
  MasteryStatus.weak: '薄弱',
  MasteryStatus.unknown: '未学',
};

/// 掌握度标签配色（语义约定同 save_topic capsule）：
/// mastered→tertiary、learning→primary、weak→error、unknown→outline。
Color _masteryColor(MasteryStatus s, ColorScheme cs) => switch (s) {
      MasteryStatus.mastered => cs.tertiary,
      MasteryStatus.learning => cs.primary,
      MasteryStatus.weak => cs.error,
      MasteryStatus.unknown => cs.outline,
    };

/// 「相关知识点」卡片列表：AI 推荐给用户的库中已有知识点。
///
/// [items] 由渲染器解析工具结果 JSON 后的结构化条目；空列表不应传入
/// （渲染器对空结果回退普通轨迹行，不渲染本卡片）。
class RecommendTopicsCard extends ConsumerWidget {
  const RecommendTopicsCard({super.key, required this.items});

  final List<RecommendTopicsItem> items;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final paper = theme.extension<PaperColors>();

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: paper?.polaroidBg ?? cs.surfaceContainerLow,
        border: Border.all(
          color: paper?.ruleSoft ?? cs.outlineVariant,
          width: 0.8,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: Row(
              children: [
                Icon(
                  Icons.auto_awesome_outlined,
                  size: 16,
                  color: paper?.stampRed ?? cs.primary,
                ),
                const SizedBox(width: 6),
                Text(
                  '相关知识点',
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ),
          Divider(height: 1, thickness: 0.5, color: cs.outlineVariant),
          for (final item in items) _ItemRow(item: item),
        ],
      ),
    );
  }
}

/// 卡片内单条知识点行：标题 + 分类路径 + 掌握度标签，点按进详情页。
class _ItemRow extends ConsumerWidget {
  const _ItemRow({required this.item});

  final RecommendTopicsItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final paper = theme.extension<PaperColors>();
    final masteryAsync = ref.watch(masteryOfProvider(item.id));

    return InkWell(
      key: ValueKey('recommend_topic_${item.id}'),
      onTap: () => context.push('/topic/${item.id}'),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Icon(
              Icons.style_outlined,
              size: 18,
              color: paper?.stampRed ?? cs.primary,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  if (item.path.isNotEmpty)
                    Text(
                      item.path,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: cs.onSurfaceVariant),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            masteryAsync.maybeWhen(
              orElse: () => const SizedBox.shrink(),
              data: (m) => Text(
                _masteryLabel[m] ?? '未学',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: _masteryColor(m, cs),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 4),
            Icon(Icons.chevron_right, color: cs.onSurfaceVariant, size: 20),
          ],
        ),
      ),
    );
  }
}