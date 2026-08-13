import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// 把一个 widget 渲染成 PNG 字节。
///
/// 用法：在 [RepaintBoundary] 外包一个 [GlobalKey]，页面 build 时把卡片填进去，
/// 分享时调用本函数截图。对齐 crop_service.dart 的纯函数 + `dart:ui` 风格，
/// 不引入新 pub 依赖，不写盘（返回内存字节，与 CapturedScreenshot 哲学一致）。
///
/// [pixelRatio] 决定导出分辨率：逻辑尺寸 × pixelRatio。分享卡取 3 → 1080×1440 清晰度。
/// 调用方须保证 [key] 当前已挂载且 [RepaintBoundary] 已在首帧后绘制完成；
/// 否则抛 [StateError]，由调用方 catch 提示用户重试。
Future<Uint8List> captureWidget(
  GlobalKey key, {
  double pixelRatio = 3,
}) async {
  final ctx = key.currentContext;
  if (ctx == null) {
    throw StateError('RepaintBoundary 尚未挂载，无法截图。');
  }
  final boundary = ctx.findRenderObject();
  if (boundary is! RenderRepaintBoundary) {
    throw StateError('GlobalKey 未关联 RepaintBoundary（实际为 $boundary）。');
  }

  final image = await boundary.toImage(pixelRatio: pixelRatio);
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) {
      throw StateError('PNG 编码失败。');
    }
    return data.buffer.asUint8List();
  } finally {
    // ui.Image 是 GPU 资源，用毕必释放，防泄漏。
    image.dispose();
  }
}