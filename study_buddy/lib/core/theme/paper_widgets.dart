// study_buddy/lib/core/theme/paper_widgets.dart
import 'package:flutter/material.dart';

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
      // Stack 叠四角 L 形订书钉角标。本任务先保留 home_page 原 Painter 内联，
      // Task 3 抽到 CornerMark 后改 import。
      child: Stack(
        children: [
          child,
          Positioned(
            top: 8,
            left: 8,
            child: CustomPaint(
              size: const Size(18, 18),
              painter: _CornerMarkPainter(
                color: theme.colorScheme.outlineVariant,
                corner: _Corner.topLeft,
              ),
            ),
          ),
          Positioned(
            bottom: 8,
            right: 8,
            child: CustomPaint(
              size: const Size(18, 18),
              painter: _CornerMarkPainter(
                color: theme.colorScheme.outlineVariant,
                corner: _Corner.bottomRight,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 订书钉角标位置。公开给本文件 _CornerMarkPainter 使用。
enum _Corner { topLeft, bottomRight }

class _CornerMarkPainter extends CustomPainter {
  const _CornerMarkPainter({required this.color, required this.corner});

  final Color color;
  final _Corner corner;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    switch (corner) {
      case _Corner.topLeft:
        canvas.drawLine(Offset.zero, Offset(size.width, 0), paint);
        canvas.drawLine(Offset.zero, Offset(0, size.height), paint);
      case _Corner.bottomRight:
        canvas.drawLine(Offset(0, size.height), Offset(size.width, size.height), paint);
        canvas.drawLine(Offset(size.width, 0), Offset(size.width, size.height), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _CornerMarkPainter oldDelegate) =>
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
