// Android 系统分享接收：把外部 App（相册/浏览器/微信等）分享出来的图片，
// 转成 [CapturedScreenshot] 供 AI 面板消费。
//
// 实现：EventChannel(`study_buddy/share`) 监听原生 MainActivity 推送的图片 bytes。
// 原生侧（MainActivity.kt）在 ACTION_SEND / SEND_MULTIPLE 时读 content Uri → bytes：
// - 热启动：App 已在前台，onNewIntent → shareSink 直接推给本 stream；
// - 冷启动：App 被杀后从分享打开，onStart 读 intent → 暂存静态 holder，
//   Flutter 订阅触发 onListen → flush 给本 stream。
// 两条路径最终都汇入 EventChannel stream，故 Dart 侧无需区分冷/热，统一订阅即可。
//
// 多图分享（SEND_MULTIPLE）只取第一张图进 AI 面板（原生侧处理，与悬浮球回流行为一致）。
// MIME 判定：原生方案仅传裸 bytes，无 mime 信息，统一按 image/jpeg 拼 data URI
// （相册/微信分享绝大多数为 JPEG；PNG 图走 /crop 重编码后统一为 PNG，AI 侧按字节
// 内容识别，不影响正确性）。
import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/logger_service.dart';
import 'captured_image.dart';

/// 热启动分享图片 holder：app.dart 在 resumed 时取出，弹 AI 面板后置 null。
class ShareIntentNotifier extends Notifier<CapturedScreenshot?> {
  @override
  CapturedScreenshot? build() => null;

  /// 写入新分享图片。已有未消费项时覆盖（取最新一张）。
  void set(CapturedScreenshot? value) => state = value;

  /// 取出并置 null（消费语义）。
  CapturedScreenshot? consume() {
    final v = state;
    state = null;
    return v;
  }
}

final shareIntentProvider =
    NotifierProvider<ShareIntentNotifier, CapturedScreenshot?>(
  ShareIntentNotifier.new,
);

const _shareChannel = EventChannel('study_buddy/share');

/// 启动分享接收订阅。
///
/// 订阅 `study_buddy/share` EventChannel，每次收到 bytes 就构造 [CapturedScreenshot]
/// 存入 [ShareIntentNotifier]，供 app.dart 在 resumed 时取出弹 AI 面板。
///
/// 冷启动：App 被杀后从分享菜单打开，Native onStart 已把分享 bytes 暂存到
/// MainActivity 静态 holder；本订阅触发原生 onListen → flush → 本 stream 收到，
/// 同样走 [ShareIntentNotifier]（不需要 PendingScreenshotStore 静态字段双通道）。
///
/// 返回 `StreamSubscription<dynamic>`，调用方必须在 dispose 时 cancel。
StreamSubscription<dynamic> bootstrapShareIntent({
  required ShareIntentNotifier notifier,
}) {
  return _shareChannel.receiveBroadcastStream().listen(
    (bytes) {
      if (bytes is! Uint8List || bytes.isEmpty) return;
      notifier.set(_bytesToCaptured(bytes));
    },
    onError: (e, st) {
      LoggerService.instance.e('分享 Intent 流错误: $e',
          category: LogCategory.ui, stackTrace: st.toString(), tags: const ['share-intent']);
    },
  );
}

/// bytes → CapturedScreenshot：原生侧只传裸字节（无 mime 信息），
/// 统一拼 `data:image/jpeg;base64,`（相册/微信分享多为 JPEG；AI 按字节内容识别）。
CapturedScreenshot _bytesToCaptured(Uint8List bytes) {
  final b64 = base64Encode(bytes);
  return CapturedScreenshot(bytes, 'data:image/jpeg;base64,$b64');
}
