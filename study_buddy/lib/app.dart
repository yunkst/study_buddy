import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/providers/screenshot_provider.dart';
import 'core/theme/app_theme.dart';
import 'router.dart';
import 'main.dart';

class StudyBuddyApp extends ConsumerStatefulWidget {
  const StudyBuddyApp({super.key});
  @override
  ConsumerState<StudyBuddyApp> createState() => _StudyBuddyAppState();
}

class _StudyBuddyAppState extends ConsumerState<StudyBuddyApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 延迟到首帧后初始化（router 就绪）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      bootstrapOverlay(ref, context);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 从设置返回 / 被截图拉回前台 → 重新检查待处理截图
    if (state == AppLifecycleState.resumed) {
      _checkPending();
    }
  }

  Future<void> _checkPending() async {
    final sp = ref.read(screenshotProvider);
    final pending = await sp.takePendingScreenshot();
    if (pending != null && mounted) {
      PendingScreenshotStore.pending = pending;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Study Buddy',
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.system,
      routerConfig: buildRouter(),
    );
  }
}