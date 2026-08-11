// 学习伙伴 Onboarding:5 节纸感分页引导页。
// 前 4 节为通用 _OnboardingStep(印章序号 + icon + 说明),
// 第 5 节暂用 _FormPlaceholder 占位(Task 10 替换为真实 LLM 配置表单)。
// 底部固定区 _BottomBar:跳过 / 圆点指示器 / 下一步·完成。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/dashed_border.dart';
import '../../core/theme/paper_scaffold.dart';
import '../../core/theme/paper_widgets.dart';

class OnboardingPage extends ConsumerStatefulWidget {
  const OnboardingPage({super.key});
  @override
  ConsumerState<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends ConsumerState<OnboardingPage> {
  final PageController _pc = PageController();
  int _index = 0;
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
                children: const [
                  _OnboardingStep(
                    ordinal: '一', icon: Icons.screenshot_monitor,
                    title: '截图悬浮球',
                    body: '任意界面点悬浮球，框选题目，AI 拆知识点。',
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
                  _OnboardingStep(
                    ordinal: '五', icon: Icons.key,
                    title: '配置 AI',
                    body: '占位 — Task 10 替换为表单',
                    showForm: true, // 标记本步非通用结构
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
            ),
          ],
        ),
      ),
    );
  }

  void _finish({required bool skipped}) {
    // Task 10 完整实现:写 prefs + (可选)写 llm_config + context.go('/')
    debugPrint('[onboarding] finish skipped=$skipped');
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
    this.showForm = false,
  });
  final String ordinal;
  final IconData icon;
  final String title;
  final String body;
  final bool showForm;

  @override
  Widget build(BuildContext context) {
    if (showForm) {
      // Task 10 替换为真实 _OnboardingStepForm
      return const _FormPlaceholder();
    }
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

class _FormPlaceholder extends StatelessWidget {
  const _FormPlaceholder();
  @override
  Widget build(BuildContext context) => const Center(child: Text('Form 占位 (Task 10)'));
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
              style: theme.textTheme.titleMedium?.copyWith(
                fontFamily: 'NotoSerifSC',
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
class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.index, required this.total,
    required this.onSkip, required this.onNext, required this.onDone,
  });
  final int index;
  final int total;
  final VoidCallback onSkip;
  final VoidCallback onNext;
  final VoidCallback onDone;

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
            FilledButton(onPressed: onDone, child: const Text('完成，开始使用')),
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
