// study_buddy/lib/core/theme/paper_widgets.dart
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'dashed_border.dart';
import 'paper_extension.dart';

/// 纸感文章块通用容器：纸白底 + 边 + 暖阴影 + 四角订书钉 L 形角标。
/// 还原 design-preview/02-paper.html `.article`。
class PaperArticle extends StatelessWidget {
  const PaperArticle({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final paper = theme.extension<PaperColors>()!;
    return Container(
      margin: const EdgeInsets.only(top: 24),
      padding: const EdgeInsets.fromLTRB(22, 24, 22, 24),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLowest,
        border: Border.all(color: theme.colorScheme.outlineVariant),
        boxShadow: [
          BoxShadow(color: paper.warmShadow, blurRadius: 24, offset: const Offset(0, 8)),
        ],
      ),
      // Stack 叠四角 L 形订书钉角标，使用公开 CornerMarkPainter。
      child: Stack(
        children: [
          child,
          Positioned(
            top: 8,
            left: 8,
            child: CustomPaint(
              size: const Size(18, 18),
              painter: CornerMarkPainter(
                color: theme.colorScheme.outlineVariant,
                corner: CornerMark.topLeft,
              ),
            ),
          ),
          Positioned(
            bottom: 8,
            right: 8,
            child: CustomPaint(
              size: const Size(18, 18),
              painter: CornerMarkPainter(
                color: theme.colorScheme.outlineVariant,
                corner: CornerMark.bottomRight,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 订书钉角标位置。公开给本文件 CornerMarkPainter 使用。
enum CornerMark { topLeft, bottomRight }

class CornerMarkPainter extends CustomPainter {
  const CornerMarkPainter({required this.color, required this.corner});

  final Color color;
  final CornerMark corner;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    switch (corner) {
      case CornerMark.topLeft:
        canvas.drawLine(Offset.zero, Offset(size.width, 0), paint);
        canvas.drawLine(Offset.zero, Offset(0, size.height), paint);
      case CornerMark.bottomRight:
        canvas.drawLine(Offset(0, size.height), Offset(size.width, size.height), paint);
        canvas.drawLine(Offset(size.width, 0), Offset(size.width, size.height), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CornerMarkPainter oldDelegate) =>
      color != oldDelegate.color || corner != oldDelegate.corner;
}

/// 文章块小标题：朱砂斜体下划线。
/// 还原 design-preview/02-paper.html `.article-label`。
class PaperArticleLabel extends StatelessWidget {
  const PaperArticleLabel({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.only(bottom: 2),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: theme.colorScheme.primary, width: 1),
        ),
      ),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(
          fontFamily: 'NotoSerifSC',
          fontStyle: FontStyle.italic,
          fontSize: 13,
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }
}

/// 印章式 Icon：外层 DashedBorder 虚线环 + 内层实线边 + 居中 Icon，整体 -3° 倾斜。
/// 还原 design-preview/02-paper.html `.stamp`。
class PaperStampIcon extends StatelessWidget {
  const PaperStampIcon({super.key, required this.icon, this.iconSize = 40});

  final IconData icon;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.primary;
    return Transform.rotate(
      angle: -3 * math.pi / 180,
      child: Container(
        foregroundDecoration: ShapeDecoration(
          shape: DashedBorder(
            radius: 0,
            dash: 4,
            gap: 3,
            color: color.withValues(alpha: 0.3),
            width: 1,
          ),
        ),
        padding: const EdgeInsets.all(3),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            border: Border.all(color: color, width: 2),
            color: theme.colorScheme.surfaceContainerLowest,
          ),
          child: Icon(icon, size: iconSize, color: color),
        ),
      ),
    );
  }
}

/// 金边提示卡：goldContainer 底 + gold 左 3px 边 + 标签 + 提示正文。
/// 还原 design-preview/02-paper.html `.tip-card`。
class PaperTipCard extends StatelessWidget {
  const PaperTipCard({super.key, required this.label, required this.text});

  final String label;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final paper = theme.extension<PaperColors>()!;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        color: paper.goldContainer,
        border: Border(
          left: BorderSide(color: paper.gold, width: 3),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              fontFamily: 'NotoSerifSC',
              fontWeight: FontWeight.w700,
              fontSize: 13,
              color: paper.gold,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                fontSize: 12.5,
                height: 1.7,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
