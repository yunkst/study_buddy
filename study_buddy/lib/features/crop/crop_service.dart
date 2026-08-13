// 拍题图片裁剪：纯函数服务层（解码 + 坐标映射 + 像素重编码 + 降采样）。
//
// 与 UI 解耦：本文件不持有 widget 状态，只提供可单测的纯函数。
// widget 层（image_crop_page.dart）负责手势与显示坐标，确认时调
// [mapDisplayRectToPixelRect] + [cropToPng] 得到裁剪后的 [CapturedScreenshot]；
// 首帧渲染后异步调 [downsampleToRgba] 得到小图 RGBA，喂给 isolate 跑主体识别。
//
// 不引入新 pub 依赖：全程走 `dart:ui`（instantiateImageCodec / PictureRecorder
// / Canvas.drawImageRect / toImage / toByteData(png|rawStraightRgba)）。image_picker 输出的
// JPEG / PNG / WebP 源，经 decodeSourceImage 后统一为 ui.Image，再重编码为 PNG，
// 对齐 [CapturedScreenshot.pngBytes] 的命名与 LLM 视觉数据 URI 约定。
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart' show Rect, Size;

import '../../core/providers/captured_image.dart';

/// 把图片字节解码为 [ui.Image]。调用方负责对返回值调用 `dispose()`。
///
/// 走 `instantiateImageCodec`：支持 Flutter 支持的所有图片格式（JPEG/PNG/WebP/GIF）。
/// image_picker 已在 Android/iOS 自动应用 EXIF 旋转，返回的 ui.Image 是已纠正方向的位图。
Future<ui.Image> decodeSourceImage(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  // codec 不会自动释放，释放掉避免泄漏（frame.image 的生命周期由调用方管理）。
  codec.dispose();
  return frame.image;
}

/// 把「显示空间（CustomPaint 局部坐标系）」的裁剪框 [displayCropRect]
/// 映射到「原图像素空间」的 srcRect，供 [cropToPng] 使用。
///
/// [displayImageRect] 是图片经 `FittedBox(BoxFit.contain)` 在 CustomPaint 中
/// 实际占用的局部矩形（左上角不一定在原点，因为 contain 会居中留白）。
/// [imagePixelSize] 是 [ui.Image.width/height]（原图像素尺寸）。
///
/// 算法：先求裁剪框相对于图片显示矩形的相对偏移，再按「像素 / 显示」比例缩放，
/// 最后 clamp 到 `[0, imagePixelSize]` 防止浮点越界。
Rect mapDisplayRectToPixelRect({
  required Rect displayImageRect,
  required Rect displayCropRect,
  required Size imagePixelSize,
}) {
  if (displayImageRect.width == 0 || displayImageRect.height == 0) {
    return Rect.zero;
  }
  final scaleX = imagePixelSize.width / displayImageRect.width;
  final scaleY = imagePixelSize.height / displayImageRect.height;
  // 先求裁剪框与图片显示矩形的交集（裁剪框不应超出图片范围）。
  final clipped = displayCropRect.intersect(displayImageRect);
  // 平移到「以图片显示矩形左上角为原点」的局部坐标，再缩放到像素空间。
  final left = (clipped.left - displayImageRect.left) * scaleX;
  final top = (clipped.top - displayImageRect.top) * scaleY;
  final width = clipped.width * scaleX;
  final height = clipped.height * scaleY;
  return Rect.fromLTWH(
    left.clamp(0, imagePixelSize.width).toDouble(),
    top.clamp(0, imagePixelSize.height).toDouble(),
    width.clamp(0, imagePixelSize.width).toDouble(),
    height.clamp(0, imagePixelSize.height).toDouble(),
  );
}

/// 约束 [rect]：不超出 [bounds]，且宽高均不小于 [minSide]。
///
/// 用于手势拖动时实时约束裁剪框：
/// - 越界时整体回缩到 bounds 内；
/// - 宽/高小于 minSide 时撑到 minSide（若 bounds 本身不足 minSide，则取 bounds 尺寸）。
Rect clampRect({
  required Rect rect,
  required Rect bounds,
  double minSide = 48,
}) {
  final maxW = bounds.width;
  final maxH = bounds.height;
  final effectiveMinW = minSide < maxW ? minSide : maxW;
  final effectiveMinH = minSide < maxH ? minSide : maxH;
  final width = rect.width.clamp(effectiveMinW, maxW).toDouble();
  final height = rect.height.clamp(effectiveMinH, maxH).toDouble();
  final left = rect.left.clamp(bounds.left, bounds.right - width).toDouble();
  final top = rect.top.clamp(bounds.top, bounds.bottom - height).toDouble();
  return Rect.fromLTWH(left, top, width, height);
}

/// 在像素空间裁剪 [source] 的 [srcRect] 区域，重编码为 PNG，封装为 [CapturedScreenshot]。
///
/// 实现：`PictureRecorder` + `Canvas.drawImageRect(source, srcRect, dstRect, paint)`
/// 把裁剪区域 1:1 画到目标尺寸，`toImage(w,h)` 得到新 ui.Image，
/// `toByteData(format: png)` 取字节，base64 编码后拼 `data:image/png;base64,` URI。
///
/// [srcRect] 必须在 `Rect.fromLTWH(0,0,source.width,source.height)` 范围内且尺寸 > 0，
/// 否则抛 [ArgumentError]。临时产生的 ui.Image / PictureRecorder 在函数内 dispose。
Future<CapturedScreenshot> cropToPng({
  required ui.Image source,
  required Rect srcRect,
}) async {
  final imgRect = Rect.fromLTWH(
    0,
    0,
    source.width.toDouble(),
    source.height.toDouble(),
  );
  if (!imgRect.overlaps(srcRect) || srcRect.width <= 0 || srcRect.height <= 0) {
    throw ArgumentError.value(srcRect, 'srcRect', '裁剪区域与源图无交集或尺寸非法');
  }
  // 与源图取交集，防止 srcRect 越界（理论上不应发生，做防御）。
  final effective = srcRect.intersect(imgRect);
  final w = effective.width.round().clamp(1, 8192);
  final h = effective.height.round().clamp(1, 8192);

  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  final dstRect = Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble());
  canvas.drawImageRect(
    source,
    effective,
    dstRect,
    ui.Paint()..filterQuality = ui.FilterQuality.medium,
  );
  final picture = recorder.endRecording();
  final croppedImage = await picture.toImage(w, h);
  final byteData = await croppedImage.toByteData(format: ui.ImageByteFormat.png);

  croppedImage.dispose();
  picture.dispose();

  final pngBytes = byteData!.buffer.asUint8List();
  final b64 = base64Encode(pngBytes);
  return CapturedScreenshot(pngBytes, 'data:image/png;base64,$b64');
}

/// 降采样后的 RGBA 直通字节（isolate 可发送，供主体识别）。
///
/// [rgba] 为 `rawStraightRgba` 格式（长度为 width*height*4），[width]/[height]
/// 是按原图比例取整后的实际尺寸（长边 ≤ [maxSide]）。
class DownsampledPixels {
  final Uint8List rgba;
  final int width;
  final int height;

  const DownsampledPixels(this.rgba, this.width, this.height);
}

/// 把 [source] 整图等比降采样到长边 ≤ [maxSide]，输出 RGBA 直通字节。
///
/// 复用 [cropToPng] 的 `PictureRecorder + drawImageRect` 思路：把整图画到一个
/// maxSide×(按比例) 的小 canvas，`toImage` → `toByteData(rawStraightRgba)`。
/// 临时产生的 ui.Image / PictureRecorder 在函数内 dispose。
///
/// 典型用法：`maxSide: 320`（约 0.4MB RGBA），供 `compute()` 跑主体识别，
/// 避免把整幅大图字节送进 isolate、也避免 UI isolate 内做重像素处理。
Future<DownsampledPixels> downsampleToRgba({
  required ui.Image source,
  int maxSide = 320,
}) async {
  final scale = math.min(
    math.min(maxSide / source.width, maxSide / source.height),
    1.0, // 不放大原图：小图维持原尺寸，避免无谓放大浪费
  );
  final w = math.max(1, (source.width * scale).round());
  final h = math.max(1, (source.height * scale).round());

  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawImageRect(
    source,
    Rect.fromLTWH(0, 0, source.width.toDouble(), source.height.toDouble()),
    Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    // 降采样用 low 更快、对墨迹判定足够。
    ui.Paint()..filterQuality = ui.FilterQuality.low,
  );
  final picture = recorder.endRecording();
  final small = await picture.toImage(w, h);
  final bd = await small.toByteData(format: ui.ImageByteFormat.rawStraightRgba);

  small.dispose();
  picture.dispose();

  return DownsampledPixels(bd!.buffer.asUint8List(), w, h);
}
