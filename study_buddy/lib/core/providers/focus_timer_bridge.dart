import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 专注计时通知栏的 Flutter↔原生桥接。
///
/// MethodChannel("study_buddy/focus")：
/// - start(sessionId) / stop() / isRunning() —— Flutter→原生
/// - onStopped —— 原生→Flutter（用户点了通知栏「停止」按钮）
///
/// 计时主源在 Flutter（FocusSessionNotifier），原生只负责展示通知与转发停止意图。
class FocusTimerBridge {
  static const _channel = MethodChannel('study_buddy/focus');

  void Function()? _onStopped;

  FocusTimerBridge() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onStopped') {
        _onStopped?.call();
      }
      return null;
    });
  }

  /// 启动原生前台服务（通知栏常驻计时）。
  Future<void> start(int sessionId) {
    return _channel.invokeMethod<void>('start', sessionId);
  }

  /// 停止原生前台服务（取消通知）。
  Future<void> stop() {
    return _channel.invokeMethod<void>('stop');
  }

  /// 原生服务是否仍在运行。
  Future<bool> isRunning() async {
    final result = await _channel.invokeMethod<bool>('isRunning');
    return result ?? false;
  }

  /// 注册「用户从通知栏停止」回调。
  void setOnStopped(void Function() cb) {
    _onStopped = cb;
  }
}

final focusTimerBridgeProvider = Provider<FocusTimerBridge>((ref) {
  return FocusTimerBridge();
});
