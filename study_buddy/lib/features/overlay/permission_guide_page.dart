import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/providers/screenshot_provider.dart';

/// 首次悬浮窗权限引导页。
///
/// 说明用途（合规：截图仅用于本地 AI 分析，不上传不分享）+ 「去开启」按钮。
/// 返回后由调用方重新检查权限（用户可能从设置返回但未授权）。
class PermissionGuidePage extends ConsumerWidget {
  const PermissionGuidePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('开启截图悬浮窗')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Icon(Icons.screenshot_monitor, size: 64, color: Colors.deepPurple),
            const SizedBox(height: 16),
            const Text(
              '开启悬浮窗权限',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            const Text(
              '在任意界面点悬浮球即可框选题目区域，AI 自动分析涉及的知识点。\n\n'
              '截图仅用于本地 AI 分析，不上传、不分享。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: Colors.black54),
            ),
            const SizedBox(height: 8),
            const Text(
              '提示：部分小米机型需额外开启「后台弹出界面」权限。',
              style: TextStyle(fontSize: 12, color: Colors.orange),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              icon: const Icon(Icons.settings),
              label: const Text('去开启悬浮窗权限'),
              onPressed: () async {
                await ref.read(screenshotProvider).requestOverlayPermission();
                if (!context.mounted) return;
                // 返回首页重新检查（用户可能未授权就返回）
                Navigator.of(context).maybePop();
              },
            ),
          ],
        ),
      ),
    );
  }
}