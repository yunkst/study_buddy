// 纸感学术主题层:PaperScaffold 公共容器。
// 暖色 RadialGradient 底 + CustomPaint 横线纸纹(32px 间距、极淡 onSurface)。
// Scaffold 透明底 + Stack 叠加,接受 appBar/body 参数兼容现有页面。
// 纯 CustomPaint 绘制,不依赖任何图片 assets(避免测试环境缺资源崩溃)。
library;

import 'package:flutter/material.dart';

/// 纸感 Scaffold:在 Material Scaffold 之下叠加纸张底色与横线纹理。
///
/// 用法:将现有页面的 `Scaffold(appBar:..., body:...)` 替换为
/// `PaperScaffold(appBar:..., body:...)`,视觉即获得纸感底。
class PaperScaffold extends StatelessWidget {
  const PaperScaffold({
    super.key,
    this.appBar,
    this.body,
    this.floatingActionButton,
    this.bottomNavigationBar,
    this.resizeToAvoidBottomInset,
  });

  /// 顶部 AppBar,语义同 [Scaffold.appBar]。
  final PreferredSizeWidget? appBar;

  /// 主体内容,语义同 [Scaffold.body]。
  final Widget? body;

  final Widget? floatingActionButton;
  final Widget? bottomNavigationBar;
  final bool? resizeToAvoidBottomInset;

  /// 横线纸纹间距(逻辑像素)。
  static const double _ruleSpacing = 32.0;

  /// 横线不透明度:极淡,仅作纸纹暗示,不抢内容。
  static const double _ruleAlpha = 0.04;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    // 纸面渐变:中心略亮的暖光,边缘渐入纸色。
    // 亮色:米黄中心 → 边缘稍深;暗色:深棕中心 → 边缘更暗。
    final gradient = RadialGradient(
      center: Alignment.topCenter,
      radius: 1.4,
      colors: isDark
          ? [colorScheme.surfaceContainer, colorScheme.surface]
          : [colorScheme.surfaceContainerLowest, colorScheme.surface],
      stops: const [0.0, 1.0],
    );

    return Stack(
      children: [
        Positioned.fill(
          child: DecoratedBox(decoration: BoxDecoration(gradient: gradient)),
        ),
        Positioned.fill(
          child: CustomPaint(
            painter: _RuleLinesPainter(
              spacing: _ruleSpacing,
              color: colorScheme.onSurface.withValues(alpha: _ruleAlpha),
            ),
          ),
        ),
        Scaffold(
          backgroundColor: Colors.transparent,
          appBar: appBar,
          body: body,
          floatingActionButton: floatingActionButton,
          bottomNavigationBar: bottomNavigationBar,
          resizeToAvoidBottomInset: resizeToAvoidBottomInset,
        ),
      ],
    );
  }
}

/// 横线纸纹画笔:自顶向下,按 [spacing] 画水平细线,颜色极淡。
class _RuleLinesPainter extends CustomPainter {
  const _RuleLinesPainter({required this.spacing, required this.color});

  final double spacing;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 0.5
      ..style = PaintingStyle.stroke;

    double y = spacing;
    while (y < size.height) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
      y += spacing;
    }
  }

  @override
  bool shouldRepaint(covariant _RuleLinesPainter oldDelegate) =>
      spacing != oldDelegate.spacing || color != oldDelegate.color;
}
