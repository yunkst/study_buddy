import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app.dart';
import 'core/providers/screenshot_provider.dart';

void main() {
  runApp(const ProviderScope(child: StudyBuddyApp()));
}

/// App 启动初始化：检查权限 → 唤起悬浮球 → 取待处理截图。
///
/// 由 StudyBuddyApp 的 initState 触发（见 app.dart 改造，Task 7 Step 4）。
/// 冷启动降级：若 PendingScreenshotHolder 有待处理截图，开 AI 面板。
Future<void> bootstrapOverlay(WidgetRef ref, BuildContext context) async {
  final sp = ref.read(screenshotProvider);
  final granted = await sp.checkOverlayPermission();
  if (!granted) {
    // 未授权：不唤起悬浮球，首页会引导
    return;
  }
  await sp.showOverlay();
  // 取待处理截图（冷启动降级）
  final pending = await sp.takePendingScreenshot();
  if (pending != null && context.mounted) {
    // 延迟到首页 build 完，用 home 的 context 弹面板
    // （实际由 home_page 在 didChangeDependencies 检查，避免顶层 context 时机问题）
    // 此处仅触发：存入一个临时 holder
    PendingScreenshotStore.pending = pending;
  }
}

/// 临时存储启动期取到的待处理截图，供 home_page 取用。
class PendingScreenshotStore {
  static dynamic pending; // CapturedScreenshot?
}