import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
// image 包：纯 Dart，按 EXIF Orientation 物理旋转像素（横屏拍照方向校正）。
import 'package:image/image.dart' as im;
import 'package:image_picker/image_picker.dart';

import 'captured_image.dart'; // CapturedScreenshot

/// 拍题问 AI 的选图 helper。
///
/// 与悬浮球截图的来源不同：本 helper 处理 image_picker
/// 返回的 XFile（相机 JPEG / 相册 JPEG 或 PNG），MIME 必须按实际格式拼 data URI，
/// 否则 LLM 侧 ImageUrlPart 解析可能失败。用户取消/失败均返回 null。
Future<CapturedScreenshot?> pickImageForAi({
  required bool fromCamera,
  double? maxWidth = 1600,
  double? maxHeight = 1600,
  int? imageQuality = 85,
}) async {
  try {
    final xfile = await ImagePicker().pickImage(
      source: fromCamera ? ImageSource.camera : ImageSource.gallery,
      maxWidth: maxWidth,
      maxHeight: maxHeight,
      imageQuality: imageQuality,
      requestFullMetadata: false, // 相册 Android 13+ 免权限
    );
    if (xfile == null) return null;
    final raw = await xfile.readAsBytes();
    if (raw.isEmpty) return null;
    final mime = _resolveMime(xfile);
    // 横屏拍照方向校正：按 EXIF Orientation 物理旋转像素，失败优雅退化原样返回
    final corrected = await _normalizeOrientation(raw, mime);
    final bytes = corrected ?? raw;
    final b64 = base64Encode(bytes);
    return CapturedScreenshot(bytes, 'data:$mime;base64,$b64');
  } on Exception {
    return null; // 用户取消在部分平台抛 PlatformException
  }
}

/// MIME 三级判定：xfile.mimeType → 路径扩展名 → 默认 image/jpeg。
///
/// 绝不硬编码 png（image_picker 产物多为 JPEG）。
String _resolveMime(XFile xfile) {
  final mt = xfile.mimeType;
  if (mt != null && mt.isNotEmpty) return mt;
  final lower = xfile.path.toLowerCase();
  if (lower.endsWith('.png')) return 'image/png';
  if (lower.endsWith('.webp')) return 'image/webp';
  if (lower.endsWith('.gif')) return 'image/gif';
  return 'image/jpeg';
}

/// 按 EXIF Orientation 物理旋转像素（横屏拍照方向校正），失败优雅退化返回 null。
///
/// 仅处理 JPEG（PNG/WebP 无 EXIF orientation）。纯 Dart [`im.bakeOrientation`]
/// 在 isolate 中执行，避免解码大图卡 UI。对 orientation=1 / 无 orientation 的图
/// 是 no-op，因此幂等安全。
Future<Uint8List?> _normalizeOrientation(Uint8List bytes, String mime) async {
  if (mime != 'image/jpeg') return null;
  try {
    return await compute(_bakeInIsolate, bytes);
  } catch (_) {
    return null; // 解码失败/内存不足 → 保留原图，不阻断拍照流程
  }
}

/// compute 回调：解码 → bakeOrientation 旋正 → 重编码 JPEG（纯 Dart，可顶层）。
///
/// 重编码 quality 略高于 image_picker 的原始 85，避免二次压缩过度掉质，保持 JPEG。
Uint8List _bakeInIsolate(Uint8List bytes) {
  final img = im.decodeImage(bytes);
  if (img == null) throw StateError('decode failed');
  final baked = im.bakeOrientation(img); // orientation=1 时 no-op
  return Uint8List.fromList(im.encodeJpg(baked, quality: 90));
}
