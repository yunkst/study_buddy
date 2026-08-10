import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app.dart';
import 'core/providers/screenshot_provider.dart';

void main() {
  runApp(const ProviderScope(child: StudyBuddyApp()));
}

/// App 启动初始化：检查权限 → 唤起悬浮球 → 取待处理截图。
///
/// 由 StudyBuddyApp 的 initState 触发（见 app.dart）。
/// 冷启动降级：若 PendingScreenshotHolder 有待处理截图，存入 PendingScreenshotStore，
/// 由 MainShell.initState 的 addPostFrameCallback 消费并弹 AI 面板。
Future<void> bootstrapOverlay(WidgetRef ref, BuildContext context) async {
  final sp = ref.read(screenshotProvider);
  final granted = await sp.checkOverlayPermission();
  if (!granted) {
    // 未授权：不唤起悬浮球，悬浮窗 Tab 会引导
    return;
  }
  await sp.showOverlay();
  // 取待处理截图（冷启动降级）
  final pending = await sp.takePendingScreenshot();
  if (pending != null && context.mounted) {
    // 存入 holder，由 MainShell.initState 的 addPostFrameCallback 消费弹面板
    PendingScreenshotStore.pending = pending;
  }
}

/// 临时存储启动期取到的待处理截图，供 MainShell 首帧回调消费。
class PendingScreenshotStore {
  static dynamic pending; // CapturedScreenshot?
}