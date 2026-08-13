import 'dart:convert';

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
    final bytes = await xfile.readAsBytes();
    if (bytes.isEmpty) return null;
    final mime = _resolveMime(xfile);
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
