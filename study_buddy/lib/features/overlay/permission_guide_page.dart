import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/screenshot_provider.dart';
import '../../core/theme/dashed_border.dart';
import '../../core/theme/paper_extension.dart';
import '../../core/theme/paper_scaffold.dart';

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
              Center(child: const _StampIcon()),
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
              const _TipCard(),
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

/// 印章式大图标：Icons.screenshot_monitor 居中，
/// 外层 Container + DashedBorder 虚线环（外扩 3px），
/// 内层 Container 朱砂实线 2px 边 + 纸白底。
/// 整体 Transform.rotate(-3°) 还原 02-paper.html `.stamp` 倾斜质感。
class _StampIcon extends StatelessWidget {
  const _StampIcon();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.primary;
    return Transform.rotate(
      // 印章倾斜 -3°，与 home_page `_Stamp` 一致。
      angle: -3 * math.pi / 180,
      // 外层 Container 用 3px padding 让出间隙，虚线环画在外层边界，
      // 恰好落在实线框外 3px，还原 HTML `.stamp::after{inset:-3px}` 外扩虚线环。
      child: Container(
        foregroundDecoration: ShapeDecoration(
          shape: DashedBorder(
            radius: 0,
            dash: 4,
            gap: 3,
            color: color.withValues(alpha: 0.3),
            width: 1,
          ),
        ),
        padding: const EdgeInsets.all(3),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            border: Border.all(color: color, width: 2),
            color: theme.colorScheme.surfaceContainerLowest,
          ),
          child: Icon(
            Icons.screenshot_monitor,
            size: 40,
            color: color,
          ),
        ),
      ),
    );
  }
}

/// 金边提示卡：goldContainer 底 + gold 左边框 3px + info 图标 + 提示文本。
/// 与 home_page `_TipCard` 同源，还原 02-paper.html `.tip-card`。
class _TipCard extends StatelessWidget {
  const _TipCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final paper = theme.extension<PaperColors>()!;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: paper.goldContainer,
        border: Border(
          left: BorderSide(color: paper.gold, width: 3),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 16, color: paper.gold),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '提示：部分小米机型需额外开启「后台弹出界面」权限。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: paper.onGold,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
