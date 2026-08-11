import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/paper_extension.dart';
import '../../core/theme/paper_scaffold.dart';

/// 设置页:诊断版块含「应用日志」「LLM 调用日志」两个入口。
///
/// 纸感主题:PaperScaffold 包裹,PaperColors extension 分隔线 + NotoSerifSC 字体,
/// 列表项极简 InkWell + ruleSoft 细分隔线,不用 Material Card。
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PaperScaffold(
      appBar: AppBar(title: const Text('设置')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          children: [
            _SectionLabel(text: '诊断'),
            const SizedBox(height: 8),
            _NavRow(
              icon: Icons.article_outlined,
              label: '应用日志',
              onTap: () => context.go('/logs/app'),
            ),
            _NavRow(
              icon: Icons.smart_toy_outlined,
              label: 'LLM 调用日志',
              onTap: () => context.go('/logs/llm'),
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}

/// 版块小标题:朱砂斜体下划线小标题(NotoSerifSC italic 13)。
/// 与首页 _ArticleLabel 风格一致,但语义独立(此处是设置页分组)。
class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.only(bottom: 2),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: theme.colorScheme.primary, width: 1),
        ),
      ),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(
          fontFamily: 'NotoSerifSC',
          fontStyle: FontStyle.italic,
          fontSize: 13,
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }
}

/// 极简导航行:左图标 + 标题 + 右 chevron,下沿 ruleSoft 细分隔线。
/// 与首页 _PlanRow 风格一致,避免 Material Card 破坏纸感。
class _NavRow extends StatelessWidget {
  const _NavRow({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: theme.extension<PaperColors>()!.ruleSoft,
              width: 0.6,
            ),
          ),
        ),
        child: Row(
          children: [
            Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: theme.textTheme.titleSmall?.copyWith(fontFamily: 'NotoSerifSC'),
              ),
            ),
            Icon(
              Icons.chevron_right,
              size: 20,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}
