import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/screenshot_provider.dart';
import '../../core/theme/paper_scaffold.dart';
import '../../core/theme/paper_widgets.dart';

/// 首次悬浮窗权限引导页。
///
/// 说明用途（合规：截图仅用于本地 AI 分析，不上传不分享）+ 「去开启」按钮。
/// 返回后由调用方重新检查权限（用户可能从设置返回但未授权）。
///
/// 纸感学术风格（参照 design-preview/02-paper.html）：
/// 印章式大图标 + 衬线标题 + 居中说明正文 + 金边小米提示卡 + 墨黑 FilledButton。
class PermissionGuidePage extends ConsumerWidget {
  const PermissionGuidePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return PaperScaffold(
      appBar: AppBar(title: const Text('开启截图悬浮窗')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 8),
              // 印章式大图标：朱砂实线边 + 外扩虚线环 + 倾斜 -3°。
              Center(child: const PaperStampIcon(icon: Icons.screenshot_monitor)),
              const SizedBox(height: 20),
              // 标题：衬线 headlineMedium。
              Text(
                '开启悬浮窗权限',
                style: theme.textTheme.headlineMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              // 说明正文：bodyMedium + onSurfaceVariant，居中。
              Text(
                '在任意界面点悬浮球即可框选题目区域，AI 自动分析涉及的知识点。\n\n'
                '截图仅用于本地 AI 分析，不上传、不分享。',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              // 金边小米提示卡。
              const PaperTipCard(label: '提示', text: '部分小米机型需额外开启「后台弹出界面」权限。'),
              const SizedBox(height: 24),
              // 墨黑 FilledButton（theme 已配，直接用）。
              FilledButton.icon(
                icon: const Icon(Icons.settings),
                label: const Text('去开启悬浮窗权限'),
                onPressed: () async {
                  await ref
                      .read(screenshotProvider)
                      .requestOverlayPermission();
                  if (!context.mounted) return;
                  // 返回首页重新检查（用户可能未授权就返回）
                  Navigator.of(context).maybePop();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
