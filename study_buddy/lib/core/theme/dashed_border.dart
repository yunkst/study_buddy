// 纸感学术主题层:虚线边框 ShapeBorder。
// 用于印章、已保存胶囊等需要"手撕纸/邮戳"质感的容器边框。
// 纯 CustomPainter 绘制,不依赖任何图片 assets。
library;

import 'package:flutter/material.dart';

/// 虚线矩形边框:沿圆角矩形路径以 [dash]/[gap] 交替描边。
///
/// 参数:
/// - [radius] 圆角半径(0 = 直角,纸感默认)
/// - [dash]   虚线段长度(逻辑像素)
/// - [gap]    虚线间隔长度(逻辑像素)
/// - [color]  虚线颜色
/// - [width]  虚线描边宽度
class DashedBorder extends ShapeBorder {
  const DashedBorder({
    this.radius = 0.0,
    this.dash = 4.0,
    this.gap = 3.0,
    this.color = const Color(0xFFA89880),
    this.width = 1.0,
  });

  final double radius;
  final double dash;
  final double gap;
  final Color color;
  final double width;

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.all(width);

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) {
    final inset = width / 2;
    final rrect = RRect.fromRectAndRadius(
      rect.deflate(inset),
      Radius.circular(radius),
    );
    return Path()..addRRect(rrect);
  }

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) {
    final rrect = RRect.fromRectAndRadius(
      rect,
      Radius.circular(radius),
    );
    return Path()..addRRect(rrect);
  }

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = width
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.butt;

    final inset = width / 2;
    final rrect = RRect.fromRectAndRadius(
      rect.deflate(inset),
      Radius.circular(radius),
    );
    final path = Path()..addRRect(rrect);

    // 沿圆角矩形路径生成虚线 metrics,逐段绘制 dash。
    final metrics = path.computeMetrics();
    final step = dash + gap;
    if (step <= 0) return;

    for (final metric in metrics) {
      final length = metric.length;
      double distance = 0;
      while (distance < length) {
        final end = (distance + dash).clamp(0.0, length);
        canvas.drawPath(metric.extractPath(distance, end), paint);
        distance += step;
      }
    }
  }

  @override
  ShapeBorder scale(double t) => DashedBorder(
        radius: radius * t,
        dash: dash * t,
        gap: gap * t,
        color: color,
        width: width * t,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DashedBorder &&
          radius == other.radius &&
          dash == other.dash &&
          gap == other.gap &&
          color == other.color &&
          width == other.width;

  @override
  int get hashCode => Object.hash(radius, dash, gap, color, width);
}
