// 裁剪框绘制层：图片 + 暗化遮罩 + 裁剪框 + L 角标 + 8 调整手柄。
//
// 绘制顺序：
//   1) _drawImage   把整幅源图画到 imageDisplayRect（亮色铺底）；
//   2) _drawDimMask 用 Path(evenOdd) = 「整画布 − 裁剪框」填半透明黑，压暗框外；
//   3) _drawFrame   描裁剪框白实线 + 四角朱砂 L 角标（借鉴 CornerMarkPainter 风格）；
//   4) _drawHandles 画 8 手柄：四角实心白圆，四边中点空心白圆，frameColor 描边。
//
// frameColor / handleColor / mask 由上层按亮暗主题装配（image_crop_page.dart）。
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// 图片裁剪框画笔。[imageDisplayRect] 与 [cropRect] 均为 CustomPaint 局部坐标系。
class CropFramePainter extends CustomPainter {
  const CropFramePainter({
    required this.image,
    required this.imageDisplayRect,
    required this.cropRect,
    required this.frameColor,
    required this.handleColor,
    this.handleRadius = 6,
    this.mask = 0.45,
  });

  /// 源图（已解码），用于 Canvas 同步绘制。
  final ui.Image image;

  /// 图片经 BoxFit.contain 后的显示矩形（局部坐标系）。
  final Rect imageDisplayRect;

  /// 当前裁剪框（局部坐标系，始终 ⊆ imageDisplayRect）。
  final Rect cropRect;

  /// 裁剪框边线 + 手柄描边色（亮色用朱砂 stampRed，暗色用亮化）。
  final Color frameColor;

  /// 裁剪框外线 + 手柄填充色（亮色用 polaroidBg 白，暗色用 polaroidBg 暗纸）。
  final Color handleColor;

  /// 角点手柄半径（逻辑 px）；边中点按 [_edgeHandleScale] 缩小。
  final double handleRadius;

  /// 裁剪框外遮罩的不透明度（0~1），暗色模式建议调小。
  final double mask;

  /// L 角标臂长（从裁剪框角点向内的两段短横/竖线长度）。
  static const double _arm = 16;

  /// 边中点手柄占角点手柄的比例。
  static const double _edgeHandleScale = 0.8;

  @override
  void paint(Canvas canvas, Size size) {
    _drawImage(canvas);
    _drawDimMask(canvas, size);
    _drawFrame(canvas);
    _drawHandles(canvas);
  }

  /// 把整幅源图铺到 imageDisplayRect（亮色打底）。
  void _drawImage(Canvas canvas) {
    if (imageDisplayRect.isEmpty || image.width <= 0 || image.height <= 0) return;
    final src = Rect.fromLTWH(
      0,
      0,
      image.width.toDouble(),
      image.height.toDouble(),
    );
    canvas.drawImageRect(
      image,
      src,
      imageDisplayRect,
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  /// 画裁剪框外的暗化遮罩：Path(evenOdd) = 整画布 − 裁剪框。
  void _drawDimMask(Canvas canvas, Size size) {
    final path = Path()
      ..addRect(Offset.zero & size)
      ..addRect(cropRect)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(
      path,
      Paint()..color = Colors.black.withValues(alpha: mask),
    );
  }

  /// 描裁剪框外线 + 四角朱砂 L 角标。
  void _drawFrame(Canvas canvas) {
    if (cropRect.isEmpty) return;
    final framePaint = Paint()
      ..color = handleColor // 白底框线
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawRect(cropRect, framePaint);

    // 四角 L 角标：frameColor（朱砂），从角点向框内延伸 _arm。
    final lt = cropRect.topLeft;
    final rt = cropRect.topRight;
    final rb = cropRect.bottomRight;
    final lb = cropRect.bottomLeft;
    final markPaint = Paint()
      ..color = frameColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    // 左上 ┐
    canvas.drawLine(lt, lt + Offset(_arm, 0), markPaint);
    canvas.drawLine(lt, lt + Offset(0, _arm), markPaint);
    // 右上 ┌
    canvas.drawLine(rt, rt - Offset(_arm, 0), markPaint);
    canvas.drawLine(rt, rt + Offset(0, _arm), markPaint);
    // 右下 └
    canvas.drawLine(rb, rb - Offset(_arm, 0), markPaint);
    canvas.drawLine(rb, rb - Offset(0, _arm), markPaint);
    // 左下 ┘
    canvas.drawLine(lb, lb + Offset(_arm, 0), markPaint);
    canvas.drawLine(lb, lb - Offset(0, _arm), markPaint);
  }

  /// 画 8 手柄：四角实心白圆，四边中点空心圆（仅描边）。
  void _drawHandles(Canvas canvas) {
    if (cropRect.isEmpty) return;
    final r = handleRadius;
    final rEdge = r * _edgeHandleScale;

    final fillPaint = Paint()..color = handleColor;
    final strokePaint = Paint()
      ..color = frameColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    // 四角：实心 handleColor + frameColor 描边。
    final corners = <Offset>[
      cropRect.topLeft,
      cropRect.topRight,
      cropRect.bottomLeft,
      cropRect.bottomRight,
    ];
    for (final c in corners) {
      canvas.drawCircle(c, r, fillPaint);
      canvas.drawCircle(c, r, strokePaint);
    }

    // 四边中点：空心圆（无填充，仅描边）。
    final edges = <Offset>[
      Offset(cropRect.center.dx, cropRect.top), // N
      Offset(cropRect.center.dx, cropRect.bottom), // S
      Offset(cropRect.left, cropRect.center.dy), // W
      Offset(cropRect.right, cropRect.center.dy), // E
    ];
    for (final e in edges) {
      canvas.drawCircle(e, rEdge, strokePaint);
    }
  }

  @override
  bool shouldRepaint(covariant CropFramePainter oldDelegate) =>
      image != oldDelegate.image ||
      imageDisplayRect != oldDelegate.imageDisplayRect ||
      cropRect != oldDelegate.cropRect ||
      frameColor != oldDelegate.frameColor ||
      handleColor != oldDelegate.handleColor ||
      handleRadius != oldDelegate.handleRadius ||
      mask != oldDelegate.mask;
}