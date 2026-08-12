import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:study_engine/study_engine.dart';

import '../../core/providers/app_update_provider.dart';
import '../../core/providers/llm_config_provider.dart';
import '../../core/theme/paper_extension.dart';
import '../../core/theme/paper_scaffold.dart';
import '../../core/update/app_update_service.dart';
import '../../core/update/models/update_check_result.dart';

/// 设置页:诊断版块含「应用日志」「LLM 调用日志」两个入口 + LLM 配置板块。
///
/// 纸感主题:PaperScaffold 包裹,PaperColors extension 分隔线 + NotoSerifSC 字体,
/// 列表项极简 InkWell + ruleSoft 细分隔线,不用 Material Card。
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PaperScaffold(
      appBar: AppBar(title: const Text('设置')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          children: [
            _LlmConfigSection(),
            const SizedBox(height: 32),
            const _SectionLabel(text: '系统'),
            const SizedBox(height: 8),
            const _OverlayPermissionRow(),
            const _VersionRow(),
            const _AboutRow(),
            const SizedBox(height: 32),
            const _SectionLabel(text: '诊断'),
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

/// 系统分组:悬浮窗权限 / 版本更新 / 关于。
///
/// 三个入口复用 _NavRow 极简导航行样式,ConsumerWidget 以便访问 ref
/// (版本更新需要 ref.read 更新服务触发检查)。
class _OverlayPermissionRow extends ConsumerWidget {
  const _OverlayPermissionRow();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _NavRow(
      icon: Icons.remove_red_eye_outlined,
      label: '悬浮窗权限',
      onTap: () => context.go('/permission-guide'),
    );
  }
}

class _VersionRow extends ConsumerWidget {
  const _VersionRow();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _NavRow(
      icon: Icons.system_update_alt_outlined,
      label: '版本更新',
      onTap: () => _checkForUpdate(context, ref),
    );
  }

  /// 触发更新检查:forceCheck 忽略 1 小时频率限制,结果以 SnackBar 反馈。
  /// 与首页一致,先读预览通道开关,再按通道查 GitHub(避免 preview 版本被跳过)。
  Future<void> _checkForUpdate(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final service = ref.read(appUpdateServiceProvider);
    final preview = await AppUpdateService.isPreviewChannelEnabled();
    final result = await service.checkForUpdateDetailed(
      forceCheck: true,
      includePrerelease: preview,
    );
    if (!context.mounted) return;
    switch (result) {
      case AppUpdateAvailable(:final version):
        messenger.showSnackBar(
          SnackBar(content: Text('发现新版本 v${version.version}')),
        );
      case AppUpdateUpToDate():
        messenger.showSnackBar(const SnackBar(content: Text('已是最新版本')));
      case AppUpdateCheckFailed(:final reason):
        messenger.showSnackBar(SnackBar(content: Text('检查失败:$reason')));
    }
  }
}

class _AboutRow extends ConsumerWidget {
  const _AboutRow();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _NavRow(
      icon: Icons.info_outline,
      label: '关于',
      onTap: () => showAboutDialog(
        context: context,
        applicationName: 'Study Buddy',
        applicationVersion: '0.1.0-preview.3',
        applicationLegalese: '© Study Buddy',
      ),
    );
  }
}

class _LlmConfigSection extends ConsumerStatefulWidget {
  @override
  ConsumerState<_LlmConfigSection> createState() => _LlmConfigSectionState();
}

class _LlmConfigSectionState extends ConsumerState<_LlmConfigSection> {
  late final TextEditingController _name;
  late final TextEditingController _url;
  late final TextEditingController _key;
  late final TextEditingController _model;
  bool _loaded = false;
  bool _saving = false;

  void _ensureControllers(LlmConfig? cfg) {
    if (_loaded) return;
    _name = TextEditingController(text: cfg?.name ?? '');
    _url = TextEditingController(text: cfg?.apiUrl ?? '');
    _key = TextEditingController(text: cfg?.apiKey ?? '');
    _model = TextEditingController(text: cfg?.model ?? '');
    _loaded = true;
  }

  @override
  void dispose() {
    if (_loaded) {
      _name.dispose();
      _url.dispose();
      _key.dispose();
      _model.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final cfg = ref.read(llmConfigProvider).value;
    if (cfg == null) return;
    setState(() => _saving = true);
    try {
      await ref.read(llmConfigProvider.notifier).save(cfg.copyWith(
            name: _name.text.trim().isEmpty ? '默认配置' : _name.text.trim(),
            apiUrl: _url.text.trim(),
            apiKey: _key.text.trim(),
            model: _model.text.trim(),
          ));
      await ref.read(llmConfigProvider.notifier).refresh();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('LLM 配置已保存')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存失败:$e')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final asyncCfg = ref.watch(llmConfigProvider);
    return asyncCfg.when(
      loading: () => const Padding(
        padding: EdgeInsets.only(top: 16),
        child: Center(
            child: SizedBox(
                width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))),
      ),
      error: (e, _) => Padding(
        padding: const EdgeInsets.only(top: 16),
        child: Text('加载配置失败:$e'),
      ),
      data: (cfg) {
        _ensureControllers(cfg);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SectionLabel(text: 'LLM 配置'),
            const SizedBox(height: 8),
            _Field(label: '名称', controller: _name, hint: '如:我的模型'),
            _Field(
              label: 'API 地址',
              controller: _url,
              hint: 'https://api.example.com/v1',
              keyboard: TextInputType.url,
            ),
            _Field(
              label: 'API Key',
              controller: _key,
              hint: 'sk-...',
              obscure: true,
            ),
            _Field(
              label: '模型',
              controller: _model,
              hint: '如:gpt-4o',
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.save_outlined, size: 18),
                label: const Text('保存'),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.label,
    required this.controller,
    required this.hint,
    this.keyboard = TextInputType.text,
    this.obscure = false,
  });
  final String label;
  final TextEditingController controller;
  final String hint;
  final TextInputType keyboard;
  final bool obscure;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: theme.textTheme.labelSmall?.copyWith(
                  fontFamily: 'NotoSerifSC',
                  fontSize: 12,
                  color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 4),
          TextField(
            controller: controller,
            keyboardType: keyboard,
            obscureText: obscure,
            style: theme.textTheme.bodyMedium?.copyWith(fontFamily: 'NotoSerifSC'),
            decoration: InputDecoration(
              isDense: true,
              hintText: hint,
              hintStyle: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5)),
              enabledBorder: UnderlineInputBorder(
                borderSide: BorderSide(
                    color: theme.extension<PaperColors>()!.ruleSoft, width: 0.6),
              ),
              focusedBorder: UnderlineInputBorder(
                borderSide: BorderSide(color: theme.colorScheme.primary, width: 1),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
