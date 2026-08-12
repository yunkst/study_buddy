// AI 面板保存知识点后的可点击卡片。
//
// isNew → 朱砂「新」badge；isNew=false → 由 masteryOfProvider(id) 派生掌握度标签。
// 卡片点击 → context.push('/topic/$id') 进知识点详情。
//
// 纸感风格对齐 today_page 的 _NavRow / _SectionLabel：
// - InkWell 卡片 + ruleSoft 描边（paper.stampRed 朱砂描边兜底）
// - 标题继承 theme.textTheme.*，不写 fontFamily 字面量
// - 全部颜色走 theme.colorScheme / paper 扩展，禁硬编码 Colors.*/Color(0x...)
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:study_engine/study_engine.dart';

import '../../core/theme/paper_extension.dart';
import '../knowledge/knowledge_providers.dart';

/// 保存的掌握度标签文案：mastered→已掌握 / learning→学习中 / weak→薄弱 / unknown→未学。
const Map<MasteryStatus, String> _masteryLabel = {
  MasteryStatus.mastered: '已掌握',
  MasteryStatus.learning: '学习中',
  MasteryStatus.weak: '薄弱',
  MasteryStatus.unknown: '未学',
};

/// 掌握度标签配色（语义约定同 5.2 _MasteryChip）：
/// mastered→tertiary、learning→primary、weak→error、unknown→outline。
Color _masteryColor(MasteryStatus s, ColorScheme cs) => switch (s) {
      MasteryStatus.mastered => cs.tertiary,
      MasteryStatus.learning => cs.primary,
      MasteryStatus.weak => cs.error,
      MasteryStatus.unknown => cs.outline,
    };

/// AI 面板保存知识点后的可点击卡片。
///
/// [id] 为知识点 ID，点按 `context.push('/topic/$id')` 进详情；
/// [isNew] 为 true 时显示朱砂「新」badge（保存后首现），false 时经
/// [masteryOfProvider] 派生掌握度标签（薄/学/已掌握/未学）。
class SavedTopicCapsule extends ConsumerWidget {
  const SavedTopicCapsule({super.key, required this.id, required this.isNew});

  final int id;
  final bool isNew;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final paper = theme.extension<PaperColors>();
    final borderColor = paper?.stampRed ?? cs.primary;

    // 朱砂「新」badge 还是掌握度标签。
    final Widget badge;
    if (isNew) {
      badge = Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: borderColor,
          borderRadius: BorderRadius.circular(3),
        ),
        child: Text(
          '新',
          style: theme.textTheme.labelSmall?.copyWith(color: cs.onPrimary),
        ),
      );
    } else {
      final masteryAsync = ref.watch(masteryOfProvider(id));
      badge = masteryAsync.maybeWhen(
        orElse: () => const SizedBox.shrink(),
        data: (m) => Text(
          _masteryLabel[m] ?? '未学',
          style: theme.textTheme.labelMedium?.copyWith(
            color: _masteryColor(m, cs),
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }

    return InkWell(
      onTap: () => context.push('/topic/$id'),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: paper?.polaroidBg ?? cs.surfaceContainerLow,
          border: Border.all(
            color: paper?.ruleSoft ?? cs.outlineVariant,
            width: 0.8,
          ),
        ),
        child: Row(
          children: [
            Icon(
              Icons.style_outlined,
              size: 22,
              color: paper?.stampRed ?? cs.primary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                '已保存知识点',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '#$id',
              style: theme.textTheme.bodySmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 8),
            badge,
            const SizedBox(width: 4),
            Icon(Icons.chevron_right, color: cs.onSurfaceVariant, size: 20),
          ],
        ),
      ),
    );
  }
}