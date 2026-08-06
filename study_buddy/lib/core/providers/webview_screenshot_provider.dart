import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// WebView 截图结果。bytes 与 base64DataUri 持有同一份图片数据，调用方择一使用。
@immutable
class CapturedScreenshot {
  final Uint8List pngBytes;
  final String base64DataUri; // 形如 "data:image/png;base64,xxxx"
  const CapturedScreenshot(this.pngBytes, this.base64DataUri);
}

/// WebView 截图服务。纯内存：bytes 仅在本对象生命周期内有效，调用方负责释放。
///
/// 不写盘、不入库、不缓存——bytes 与 dataUri 仅在返回的 [CapturedScreenshot]
/// 对象生命周期内有效，由调用方自行消费（如喂给 Vision 模型）。
class WebViewScreenshotService {
  /// 截图当前 WebView 页面。返回 null 表示截图失败（页面未就绪 / 平台不支持）。
  Future<CapturedScreenshot?> capture(InAppWebViewController controller) async {
    try {
      // flutter_inappwebview 6.x: takeScreenshot() 直接返回 PNG 字节
      // (Future<Uint8List?>)，无 .image 字段。
      final bytes = await controller.takeScreenshot();
      if (bytes == null) return null;
      final b64 = base64Encode(bytes);
      return CapturedScreenshot(bytes, 'data:image/png;base64,$b64');
    } catch (_) {
      // 平台不支持 / 页面未就绪 / 用户拒绝截图权限：视为失败。
      return null;
    }
  }
}

final webViewScreenshotServiceProvider = Provider<WebViewScreenshotService>((ref) {
  return WebViewScreenshotService();
});
