import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 截图结果。bytes 与 base64DataUri 持有同一份图片数据，调用方择一使用。
///
/// 从原生截图 channel 取得（系统级 MediaProjection 截图），纯内存：
/// 不写盘、不缓存，仅在本对象生命周期内有效。
@immutable
class CapturedScreenshot {
  final Uint8List pngBytes;
  final String base64DataUri; // 形如 "data:image/png;base64,xxxx"
  const CapturedScreenshot(this.pngBytes, this.base64DataUri);
}

/// 系统级截图悬浮窗的 Flutter 侧桥接。
///
/// 通过 MethodChannel("study_buddy/overlay") 与原生通信：
/// - 权限检查 / 引导
/// - 悬浮球显隐
/// - 取待处理截图（热/冷路径统一走 PendingScreenshotHolder + take）
///
/// 原生侧（ScreenshotPlugin.kt）在 Task 2-6 实现；本 provider 先建壳，
/// 具体方法调用在原生就绪后（Task 7）验证。
class ScreenshotProvider {
  static const _channel = MethodChannel('study_buddy/overlay');

  /// 检查悬浮窗权限是否已授予。
  Future<bool> checkOverlayPermission() async {
    final result = await _channel.invokeMethod<bool>('checkOverlayPermission');
    return result ?? false;
  }

  /// 跳转系统悬浮窗权限设置页（原生侧做厂商判断 + 兜底）。
  Future<void> requestOverlayPermission() async {
    await _channel.invokeMethod<void>('requestOverlayPermission');
  }

  /// 显示悬浮球（唤起 OverlayService）。
  Future<void> showOverlay() async {
    await _channel.invokeMethod<void>('showOverlay');
  }

  /// 隐藏悬浮球。
  Future<void> hideOverlay() async {
    await _channel.invokeMethod<void>('hideOverlay');
  }

  /// 取待处理截图（从原生 PendingScreenshotHolder）。无则返回 null。
  ///
  /// 取出后原生侧自动清空。App 被拉回前台 / 冷启动时调用。
  Future<CapturedScreenshot?> takePendingScreenshot() async {
    final bytes = await _channel.invokeMethod<Uint8List>('takePendingScreenshot');
    if (bytes == null) return null;
    final b64 = base64Encode(bytes);
    return CapturedScreenshot(bytes, 'data:image/png;base64,$b64');
  }
}

final screenshotProvider = Provider<ScreenshotProvider>((ref) {
  return ScreenshotProvider();
});

/// 相机/相册 Activity 期间抑制 paused→showOverlay 的临时标志。
///
/// 背景：用户在 App 内点「拍题问 AI」时，image_picker 启动系统相机 Activity
/// 让 App 进 paused 状态。若 lifecycle 在 paused 时无条件 showOverlay，悬浮球
/// 会在系统相机界面闪现。
///
/// 用法：pickImage 前置 `set(true)`，finally 中 `set(false)`
/// （即使取消/失败）。`app.dart` 的 `didChangeAppLifecycleState` 在 paused 时
/// 读此标志判断是否跳过 showOverlay。
///
/// Riverpod 3 中 `Notifier.state` 是 protected，外部不能直接写，
/// 故通过 [SuppressOverlayNotifier.set] 暴露公开修改入口。
final suppressOverlayOnPauseProvider =
    NotifierProvider<SuppressOverlayNotifier, bool>(SuppressOverlayNotifier.new);

/// [suppressOverlayOnPauseProvider] 的 notifier：仅持有 bool 状态。
class SuppressOverlayNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  /// 设置抑制标志。pickImage 前置 `set(true)`，finally 中 `set(false)`。
  void set(bool value) => state = value;
}
