import 'package:flutter/foundation.dart';

/// 拍题 / 裁剪 / 系统分享接收共用的图片数据契约，纯内存。
///
/// `bytes` 与 `base64DataUri` 持有同一份图片数据，调用方择一使用：
/// - bytes：本地裁剪、内存展示
/// - base64DataUri：形如 `data:image/jpeg;base64,xxxx`，传给 LLM 的 ImageUrlPart
///
/// 来源可以是 App 内拍题（image_picker）、`/crop` 裁剪结果，或 Android 系统分享
/// 接收的图片。不写盘、不缓存，仅在本对象生命周期内有效。
@immutable
class CapturedScreenshot {
  final Uint8List pngBytes;
  final String base64DataUri;
  const CapturedScreenshot(this.pngBytes, this.base64DataUri);
}
