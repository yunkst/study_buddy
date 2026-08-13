// 学习伙伴 Onboarding:5 节纸感分页引导页。
// 前 4 节为通用 _OnboardingStep(印章序号 + icon + 说明),
// 第 5 节为真实 _OnboardingStepForm(LLM 配置表单),完成时写库 + 写 prefs + 跳首页。
// 底部固定区 _BottomBar:跳过 / 圆点指示器 / 下一步·完成。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:study_engine/study_engine.dart';

import '../../core/providers/database_provider.dart';
import '../../core/theme/dashed_border.dart';
import '../../core/theme/paper_scaffold.dart';
import '../../core/theme/paper_widgets.dart';
import '../../router.dart' show onboardingActive;

class OnboardingPage extends ConsumerStatefulWidget {
  const OnboardingPage({super.key});
  @override
  ConsumerState<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends ConsumerState<OnboardingPage> {
  final PageController _pc = PageController();
  final GlobalKey<_OnboardingStepFormState> _formKey =
      GlobalKey<_OnboardingStepFormState>();
  int _index = 0;
  bool _saving = false;
  bool _canSubmit = false; // 仅第 5 节有意义,控制完成按钮置灰
  static const _total = 5;

  @override
  void dispose() {
    _pc.dispose();
    super.dispose();
  }

  void _next() {
    if (_index < _total - 1) {
      _pc.nextPage(duration: const Duration(milliseconds: 280), curve: Curves.easeOut);
    }
  }

  Future<void> _finish({required bool skipped}) async {
    if (!skipped) {
      // 用户点了"完成,开始使用",先尝试写库
      setState(() => _saving = true);
      try {
        final formKey = _formKey.currentState;
        if (formKey != null) {
          // submit() 在 _canSubmit=false 时 return false 不写库（_BottomBar.enabled 已置灰
          // 按钮作主防护，此处为竞态兜底：enabled=true 时用户清空输入再点完成仍能挡住）。
          final ok = await formKey.submit();
          if (!ok) {
            if (mounted) setState(() => _saving = false);
            return;
          }
        }
      } catch (e) {
        if (mounted) {
          setState(() => _saving = false);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('保存失败：$e')),
          );
        }
        return; // 不写 prefs,留在引导页
      }
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('onboarding_done', true);
    // 写 prefs 成功,翻转 onboardingActive 以便 redirect 放行 go('/today'),
    // 否则 redirect 仍读到 true 会把 '/today' 弹回 '/onboarding' 形成死循环。
    onboardingActive.value = false;
    if (mounted) context.go('/today');
  }

  @override
  Widget build(BuildContext context) {
    return PaperScaffold(
      body: SafeArea(
        child: Column(
          children: [
            const _OnboardingMasthead(),
            Expanded(
              child: PageView(
                controller: _pc,
                onPageChanged: (i) => setState(() => _index = i),
                // 第 5 个 child 用 GlobalKey 引用 _OnboardingStepForm,
                // 不能 const(整个 children list 也去 const)。
                children: [
                  _OnboardingStep(
                    ordinal: '一', icon: Icons.share_outlined,
                    title: '分享图片问 AI',
                    body: '相册或浏览器分享图片到本 App，框选题目，AI 拆知识点。',
                  ),
                  _OnboardingStep(
                    ordinal: '二', icon: Icons.camera_alt_outlined,
                    title: '拍照问 AI',
                    body: '相册选图或拍照，AI 分析解题思路。',
                  ),
                  _OnboardingStep(
                    ordinal: '三', icon: Icons.event_note,
                    title: '学习计划',
                    body: '报考试日期目标，AI 拆里程碑节点，手动录测评看进步曲线。',
                  ),
                  _OnboardingStep(
                    ordinal: '四', icon: Icons.timer_outlined,
                    title: '专注与日报',
                    body: '专注计时锁定，结束生成学习日报。',
                  ),
                  _OnboardingStepForm(
                    key: _formKey,
                    onCanSubmitChanged: (v) {
                      if (_canSubmit != v) setState(() => _canSubmit = v);
                    },
                  ),
                ],
              ),
            ),
            _BottomBar(
              index: _index,
              total: _total,
              onSkip: () => _finish(skipped: true),
              onNext: _next,
              onDone: () => _finish(skipped: false),
              enabled: _canSubmit,
              saving: _saving,
            ),
          ],
        ),
      ),
    );
  }
}

/// 简版刊头:与 home_page._Masthead 视觉对齐,本期不抽公共。
class _OnboardingMasthead extends StatelessWidget {
  const _OnboardingMasthead();
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(width: 2, color: theme.colorScheme.outlineVariant)),
      ),
      child: Center(
        child: Text('Study Buddy · 欢迎',
            style: theme.textTheme.displayLarge?.copyWith(fontSize: 22)),
      ),
    );
  }
}

/// 单页（前 4 页通用），第 5 页用 _OnboardingStepForm 替换。
class _OnboardingStep extends StatelessWidget {
  const _OnboardingStep({
    required this.ordinal,
    required this.icon,
    required this.title,
    required this.body,
  });
  final String ordinal;
  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      child: PaperArticle(
        child: Column(
          children: [
            PaperArticleLabel(text: title),
            const SizedBox(height: 16),
            Center(child: _OnboardingSeal(ordinal: ordinal)),
            const SizedBox(height: 16),
            Icon(icon, size: 56, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 16),
            Text(body,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }
}

/// 第 5 节真实 LLM 配置表单。父级通过 GlobalKey<_OnboardingStepFormState> 调 submit()。
/// 通过 onCanSubmitChanged 把 _canSubmit 状态向上通知,控制完成按钮置灰。
class _OnboardingStepForm extends ConsumerStatefulWidget {
  const _OnboardingStepForm({super.key, this.onCanSubmitChanged});
  final ValueChanged<bool>? onCanSubmitChanged;
  @override
  ConsumerState<_OnboardingStepForm> createState() => _OnboardingStepFormState();
}

class _OnboardingStepFormState extends ConsumerState<_OnboardingStepForm> {
  final _urlCtrl = TextEditingController();
  final _keyCtrl = TextEditingController();
  final _modelCtrl = TextEditingController();
  bool _setAsDefault = true;

  @override
  void dispose() {
    _urlCtrl.dispose();
    _keyCtrl.dispose();
    _modelCtrl.dispose();
    super.dispose();
  }

  bool get _canSubmit =>
      _urlCtrl.text.trim().isNotEmpty && _keyCtrl.text.trim().isNotEmpty;

  void _notifyCanSubmit() =>
      widget.onCanSubmitChanged?.call(_canSubmit);

  /// 写 llm_config 行。父级通过 GlobalKey 调用,_canSubmit false 时直接返回 false 不写库。
  Future<bool> submit() async {
    if (!_canSubmit) return false;
    final db = await ref.read(databaseProvider.future);
    final repo = LlmConfigRepository(db);
    final model = _modelCtrl.text.trim().isEmpty
        ? 'gpt-4o-mini'
        : _modelCtrl.text.trim();
    await repo.insert(LlmConfig(
      name: '默认',
      apiUrl: _urlCtrl.text.trim(),
      apiKey: _keyCtrl.text.trim(),
      model: model,
      supportsVision: false,
      isDefault: _setAsDefault,
      sortOrder: 0,
      createdAt: DateTime.now(),
    ));
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      child: PaperArticle(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const PaperArticleLabel(text: '配置 AI'),
            const SizedBox(height: 16),
            const Center(child: _OnboardingSeal(ordinal: '五')),
            const SizedBox(height: 16),
            Text('填好以下信息，AI 才能真正可用。',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 16),
            TextField(
              controller: _urlCtrl,
              onChanged: (_) {
                setState(() {});
                _notifyCanSubmit();
              },
              decoration: const InputDecoration(
                labelText: 'API 地址',
                hintText: 'https://api.openai.com/v1',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _keyCtrl,
              onChanged: (_) {
                setState(() {});
                _notifyCanSubmit();
              },
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'API Key',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _modelCtrl,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: '模型名（可空，默认 gpt-4o-mini）',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              value: _setAsDefault,
              onChanged: (v) => setState(() => _setAsDefault = v),
              title: const Text('设为默认'),
              contentPadding: EdgeInsets.zero,
            ),
          ],
        ),
      ),
    );
  }
}

/// 印章式序号：-3° 倾斜 + DashedBorder 外环 + 实线框 + 中文序号。
class _OnboardingSeal extends StatelessWidget {
  const _OnboardingSeal({required this.ordinal});
  final String ordinal;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.primary;
    return Transform.rotate(
      angle: -3 * 3.1415926 / 180,
      child: Container(
        foregroundDecoration: ShapeDecoration(
          shape: DashedBorder(
            radius: 0, dash: 4, gap: 3,
            color: color.withValues(alpha: 0.3), width: 1,
          ),
        ),
        padding: const EdgeInsets.all(3),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
          decoration: BoxDecoration(
            border: Border.all(color: color, width: 2),
            color: theme.colorScheme.surfaceContainerLowest,
          ),
          child: Text(ordinal,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
                fontSize: 16,
                letterSpacing: 3,
                color: color,
              )),
        ),
      ),
    );
  }
}

/// 底部固定区：圆点 + 跳过 + 下一步/完成。
/// [enabled] 仅控制最后一页的"完成"按钮;[saving] 控制保存中禁用按钮。
/// "下一步"始终可点。
class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.index, required this.total,
    required this.onSkip, required this.onNext, required this.onDone,
    required this.enabled, required this.saving,
  });
  final int index;
  final int total;
  final VoidCallback onSkip;
  final VoidCallback onNext;
  final VoidCallback onDone;
  final bool enabled;
  final bool saving;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
      child: Row(
        children: [
          TextButton(onPressed: onSkip, child: const Text('跳过')),
          Expanded(child: _Dots(index: index, total: total)),
          if (index < total - 1)
            FilledButton(onPressed: onNext, child: const Text('下一步'))
          else
            FilledButton(
              onPressed: (enabled && !saving) ? onDone : null,
              child: const Text('完成，开始使用'),
            ),
        ],
      ),
    );
  }
}

class _Dots extends StatelessWidget {
  const _Dots({required this.index, required this.total});
  final int index;
  final int total;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(total, (i) {
        final active = i == index;
        return Container(
          width: active ? 8 : 6, height: active ? 8 : 6,
          margin: const EdgeInsets.symmetric(horizontal: 4),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: active ? theme.colorScheme.primary : theme.colorScheme.outlineVariant,
          ),
        );
      }),
    );
  }
}
