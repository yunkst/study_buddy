// 设置 Tab：分组设置行布局。
//
// 结构（纸感学术主题）：
//   ▏外观：主题模式（亮/暗/跟随系统）
//   ▏系统：LLM 配置（收敛为入口行，点按弹底部表单）、版本更新、关于
//   ▏诊断：应用日志、LLM 调用日志
//
// 对齐设计稿 ui-redesign-preview.html 的 .setting-row 视觉：左 icon + 文案，
// 右「当前值 + chevron」；分组小标题用朱砂斜体下划线（_SectionLabel）。
// LLM 配置不再首屏铺表单，收敛为一行入口，点按弹 showModalBottomSheet 表单，
// 与主题模式选择的底部 Sheet 交互一致（showThemeModeSheet）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:study_engine/study_engine.dart';

import '../../core/providers/app_update_provider.dart';
import '../../core/providers/daily_review_limit_provider.dart';
import '../../core/providers/dev_mode_provider.dart';
import '../../core/providers/llm_config_provider.dart';
import '../../core/providers/theme_mode_provider.dart';
import '../../core/theme/paper_extension.dart';
import '../../core/theme/paper_scaffold.dart';
import '../../core/update/app_update_service.dart';
import '../../core/update/models/update_check_result.dart';
import '../../core/update/ui/app_update_dialog.dart';

/// 设置页：分组设置行（外观 / 系统 / 诊断）。
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 提示词设置 / 预览版下载 / 应用日志 / LLM 调用日志 仅在开发者模式开启时展示。
    // 关闭时连「诊断」分组小标题一并隐藏（该分组下仅此两项）。
    final devMode = ref.watch(devModeProvider).value ?? false;
    return PaperScaffold(
      appBar: AppBar(title: const Text('设置')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          children: [
            const _SectionLabel(text: '外观'),
            const SizedBox(height: 8),
            const _ThemeModeRow(),
            const SizedBox(height: 32),
            const _SectionLabel(text: '系统'),
            const SizedBox(height: 8),
            const _LlmConfigRow(),
            if (devMode) const _PromptRow(),
            const _DailyReviewLimitRow(),
            const _VersionRow(),
            if (devMode) const _PreviewChannelRow(),
            const _AboutRow(),
            if (devMode) ...[
              const SizedBox(height: 32),
              const _SectionLabel(text: '诊断'),
              const SizedBox(height: 8),
              _NavRow(
                icon: Icons.article_outlined,
                label: '应用日志',
                onTap: () => context.push('/logs/app'),
              ),
              _NavRow(
                icon: Icons.smart_toy_outlined,
                label: 'LLM 调用日志',
                onTap: () => context.push('/logs/llm'),
              ),
            ],
            const SizedBox(height: 32),
            const _SectionLabel(text: '开发者'),
            const SizedBox(height: 8),
            const _DevModeRow(),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}

/// 版块小标题：朱砂斜体下划线小标题（NotoSerifSC italic 13）。
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
        style: theme.textTheme.headlineSmall?.copyWith(
          fontStyle: FontStyle.italic,
          fontSize: 13,
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }
}

/// 设置行：左 icon + 标题，右「可选当前值 + chevron」。
/// 对齐设计稿 .setting-row；下沿 ruleSoft 细分隔线。
class _NavRow extends StatelessWidget {
  const _NavRow({
    required this.icon,
    required this.label,
    this.value,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String? value;
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
                style: theme.textTheme.headlineSmall?.copyWith(fontSize: 14),
              ),
            ),
            if (value != null) ...[
              Text(
                value!,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 4),
            ],
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

// ─────────────────────────────────────────────────────────────
// LLM 配置入口行 + 底部表单 Sheet
// ─────────────────────────────────────────────────────────────

/// LLM 配置入口行：右侧显示「已配置 / 未配置」状态，点按弹底部表单。
class _LlmConfigRow extends ConsumerWidget {
  const _LlmConfigRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncCfg = ref.watch(llmConfigProvider);
    final configured = asyncCfg.maybeWhen(
      data: (cfg) => cfg != null && cfg.apiUrl.trim().isNotEmpty,
      orElse: () => false,
    );
    return _NavRow(
      icon: Icons.settings_ethernet_outlined,
      label: 'LLM 配置',
      value: configured ? '已配置' : '未配置',
      onTap: () => showLlmConfigSheet(context, ref),
    );
  }
}

/// 提示词入口行：点按进入「提示词设置」页（编辑 system prompt 运行时覆盖）。
class _PromptRow extends ConsumerWidget {
  const _PromptRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _NavRow(
      icon: Icons.edit_note_outlined,
      label: '提示词设置',
      value: 'AI 行为规则',
      onTap: () => context.go('/settings/prompt'),
    );
  }
}

/// LLM 配置底部表单：名称 / API 地址 / API Key / 模型 + 保存。
/// 与 showThemeModeSheet 同款 showModalBottomSheet 交互。
Future<void> showLlmConfigSheet(BuildContext context, WidgetRef ref) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _LlmConfigSheetBody(),
  );
}

class _LlmConfigSheetBody extends ConsumerStatefulWidget {
  const _LlmConfigSheetBody();

  @override
  ConsumerState<_LlmConfigSheetBody> createState() =>
      _LlmConfigSheetBodyState();
}

class _LlmConfigSheetBodyState extends ConsumerState<_LlmConfigSheetBody> {
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
        Navigator.of(context).pop(); // 保存成功收起 Sheet
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
    final theme = Theme.of(context);
    return Padding(
      // isScrollControlled 下垫键盘高度，避免输入被遮挡。
      padding: EdgeInsets.only(
        left: 24,
        right: 24,
        top: 8,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: asyncCfg.when(
        loading: () => const Center(
          child: Padding(
            padding: EdgeInsets.all(32),
            child: CircularProgressIndicator(),
          ),
        ),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Text('加载配置失败:$e'),
          ),
        ),
        data: (cfg) {
          _ensureControllers(cfg);
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'LLM 配置',
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 16),
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
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: _saving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.save_outlined, size: 18),
                  label: const Text('保存'),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// 底部表单字段：标签 + 下划线 TextField。
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
          Text(
            label,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontSize: 12,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          TextField(
            controller: controller,
            keyboardType: keyboard,
            obscureText: obscure,
            style: theme.textTheme.bodyMedium,
            decoration: InputDecoration(
              isDense: true,
              hintText: hint,
              hintStyle: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
              ),
              enabledBorder: UnderlineInputBorder(
                borderSide: BorderSide(
                  color: theme.extension<PaperColors>()!.ruleSoft,
                  width: 0.6,
                ),
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

// ─────────────────────────────────────────────────────────────
// 系统分组：版本更新 / 关于
// ─────────────────────────────────────────────────────────────

/// 版本更新行：右侧显示当前版本号，点按触发检查。
class _VersionRow extends ConsumerWidget {
  const _VersionRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 版本号运行时读取（package_info_plus），避免与 pubspec 硬编码漂移；
    // FutureProvider 首帧未就绪时显示占位，就绪后自动刷新。
    final version = ref.watch(currentVersionProvider).value ?? '…';
    return _NavRow(
      icon: Icons.system_update_alt_outlined,
      label: '版本更新',
      value: version,
      onTap: () => _checkForUpdate(context, ref),
    );
  }

  /// 触发更新检查：forceCheck 忽略 1 小时频率限制。
  /// 先读预览通道开关，再按通道查 GitHub（避免 preview 版本被跳过）；
  /// 有新版本弹下载对话框，无新版本以 SnackBar 反馈。
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
        // forceCheck 下版本相同也会返回 Available，用 hasNewVersion 区分：
        // 真新版本 → 弹下载/安装对话框；相同版本 → 提示已最新。
        final current = (await service.getCurrentVersion()).version;
        if (!context.mounted) return;
        if (service.hasNewVersion(current, version.version)) {
          await showAppUpdateDialog(
            context,
            version: version,
            updateService: service,
          );
        } else {
          messenger.showSnackBar(const SnackBar(content: Text('已是最新版本')));
        }
      case AppUpdateUpToDate():
        messenger.showSnackBar(const SnackBar(content: Text('已是最新版本')));
      case AppUpdateCheckFailed(:final reason):
        messenger.showSnackBar(SnackBar(content: Text('检查失败:$reason')));
    }
  }
}

/// 关于行：弹系统关于对话框。
class _AboutRow extends ConsumerWidget {
  const _AboutRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final version = ref.watch(currentVersionProvider).value ?? '…';
    return _NavRow(
      icon: Icons.info_outline,
      label: '关于',
      onTap: () => showAboutDialog(
        context: context,
        applicationName: 'Study Buddy',
        applicationVersion: version,
        applicationLegalese: '© Study Buddy',
      ),
    );
  }
}

/// 开关设置行：左 icon + 标题，右侧 Switch。
/// 与 _NavRow 同款视觉（icon + 标题 + 下沿细分隔线），右侧以 Switch 替代 chevron。
class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
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
              style: theme.textTheme.headlineSmall?.copyWith(fontSize: 14),
            ),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

/// 预览版下载开关行：开启后检查更新走 preview 通道，可下载预览版 APK。
/// 打开时先弹「非常不稳定」提醒，用户确认后才真正开启；关闭直接生效。
class _PreviewChannelRow extends ConsumerWidget {
  const _PreviewChannelRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(previewChannelProvider).value ?? false;
    return _SwitchRow(
      icon: Icons.science_outlined,
      label: '预览版下载',
      value: enabled,
      onChanged: (v) => _onChanged(context, ref, v),
    );
  }

  Future<void> _onChanged(BuildContext context, WidgetRef ref, bool v) async {
    final notifier = ref.read(previewChannelProvider.notifier);
    if (!v) {
      await notifier.set(false); // 关闭直接生效，无需确认
      return;
    }
    // 打开：先提醒预览版非常不稳定，确认后才开启。
    // Switch 受控于 provider，取消时未写 state，视觉不会闪亮。
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('开启预览版下载'),
        content: const Text(
          '预览版包含最新功能，但非常不稳定，可能包含 Bug 甚至崩溃，仅建议测试用途。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(false),
            child: const Text('再想想'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogCtx).pop(true),
            child: const Text('继续开启'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await notifier.set(true);
    }
  }
}

/// 开发者模式开关行：开启后 AI 对话页显示工具调用详情卡片与注入上下文。
/// 直接生效（与预览版下载不同，无需确认弹窗）。
class _DevModeRow extends ConsumerWidget {
  const _DevModeRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(devModeProvider).value ?? false;
    return _SwitchRow(
      icon: Icons.developer_mode,
      label: '开发者模式',
      value: enabled,
      onChanged: (v) => ref.read(devModeProvider.notifier).set(v),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// 系统分组：每日复习上限
// ─────────────────────────────────────────────────────────────

/// 每日复习上限行：右侧显示当前值，点按弹底部 Sheet 步进调整。
class _DailyReviewLimitRow extends ConsumerWidget {
  const _DailyReviewLimitRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final v = ref.watch(dailyReviewLimitProvider).value ??
        DailyReviewLimitNotifier.defaultValue;
    return _NavRow(
      icon: Icons.style_outlined,
      label: '每日复习上限',
      value: '$v 张',
      onTap: () => showDailyReviewLimitSheet(context, ref),
    );
  }
}

/// 每日复习上限选择底部 Sheet：居中大数字 + −/+ 步进按钮。
Future<void> showDailyReviewLimitSheet(BuildContext context, WidgetRef ref) async {
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetCtx) {
      final theme = Theme.of(sheetCtx);
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 24, right: 24, top: 4, bottom: 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '每日复习上限',
                  style: theme.textTheme.headlineSmall?.copyWith(fontSize: 14),
                ),
              ),
            ),
            // 步进器：每次 +1 / −1，clamp 由 notifier 兜底。
            Consumer(
              builder: (context, ref, _) {
                final v = ref.watch(dailyReviewLimitProvider).value ??
                    DailyReviewLimitNotifier.defaultValue;
                return _NumberStepperRow(
                  value: v,
                  onChanged: (next) =>
                      ref.read(dailyReviewLimitProvider.notifier).set(next),
                );
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );
}

/// 步进行：居中大数字 + 左右步进按钮（− / +），点按即写并即时刷新。
class _NumberStepperRow extends StatelessWidget {
  const _NumberStepperRow({required this.value, required this.onChanged});

  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child: Row(
        children: [
          IconButton.filledTonal(
            icon: const Icon(Icons.remove),
            onPressed: () => onChanged(value - 1),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Center(
              child: Text(
                '$value 张',
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          const SizedBox(width: 16),
          IconButton.filledTonal(
            icon: const Icon(Icons.add),
            onPressed: () => onChanged(value + 1),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// 外观分组：主题模式
// ─────────────────────────────────────────────────────────────

/// 主题模式行：展示当前模式，点击弹出底部 Sheet 切换。
class _ThemeModeRow extends ConsumerWidget {
  const _ThemeModeRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider).value ?? ThemeMode.system;
    return _NavRow(
      icon: Icons.brightness_6_outlined,
      label: '主题模式',
      value: _modeLabel(mode),
      onTap: () => showThemeModeSheet(context, ref),
    );
  }

  static String _modeLabel(ThemeMode mode) => switch (mode) {
        ThemeMode.system => '跟随系统',
        ThemeMode.light => '浅色',
        ThemeMode.dark => '深色',
      };
}

/// 主题模式选择底部 Sheet。
/// 三行（跟随系统/浅色/深色），选中项右侧朱砂红勾选。
Future<void> showThemeModeSheet(BuildContext context, WidgetRef ref) async {
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetCtx) {
      final theme = Theme.of(sheetCtx);
      final current = ref.watch(themeModeProvider).value ?? ThemeMode.system;
      final options = const <(ThemeMode, IconData, String)>[
        (ThemeMode.system, Icons.brightness_auto_outlined, '跟随系统'),
        (ThemeMode.light, Icons.light_mode_outlined, '浅色'),
        (ThemeMode.dark, Icons.dark_mode_outlined, '深色'),
      ];
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 24, right: 24, top: 4, bottom: 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '主题模式',
                  style: theme.textTheme.headlineSmall?.copyWith(fontSize: 14),
                ),
              ),
            ),
            for (final (mode, icon, label) in options)
              InkWell(
                onTap: () {
                  ref.read(themeModeProvider.notifier).set(mode);
                  Navigator.of(sheetCtx).pop();
                },
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
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
                          style: theme.textTheme.bodyLarge,
                        ),
                      ),
                      if (mode == current)
                        Icon(Icons.check, size: 20, color: theme.colorScheme.primary),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );
}
