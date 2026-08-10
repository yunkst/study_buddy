import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/providers/database_provider.dart';
import '../../core/providers/screenshot_provider.dart';
import '../../features/external_qbank/ai_panel_sheet.dart';
import '../../main.dart' show PendingScreenshotStore;

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});
  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  bool? _overlayGranted;

  @override
  void initState() {
    super.initState();
    _checkPermission();
    _consumePendingScreenshot();
  }

  Future<void> _checkPermission() async {
    final granted = await ref.read(screenshotProvider).checkOverlayPermission();
    if (mounted) setState(() => _overlayGranted = granted);
    if (granted) {
      await ref.read(screenshotProvider).showOverlay();
    }
  }

  Future<void> _consumePendingScreenshot() async {
    // 冷启动降级：弹出待处理截图的 AI 面板
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final pending = PendingScreenshotStore.pending;
      if (pending != null) {
        PendingScreenshotStore.pending = null;
        if (mounted) await showAiPanel(context, screenshot: pending);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final dbAsync = ref.watch(databaseProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Study Buddy')),
      body: dbAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('数据库初始化失败: $e')),
        data: (_) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _overlayGranted == true
                      ? Icons.screenshot_monitor
                      : Icons.screenshot_monitor_outlined,
                  size: 48,
                  color: Colors.deepPurple,
                ),
                const SizedBox(height: 12),
                Text(
                  _overlayGranted == null
                      ? '检查权限中...'
                      : _overlayGranted == true
                          ? '悬浮窗已开启 ✅\n在任意界面点悬浮球即可截图分析。'
                          : '悬浮窗未开启\n开启后可在任意界面截图分析。',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 16),
                ),
                const SizedBox(height: 16),
                if (_overlayGranted == false)
                  FilledButton.icon(
                    icon: const Icon(Icons.settings),
                    label: const Text('去开启悬浮窗权限'),
                    onPressed: () => context.go('/permission-guide'),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}