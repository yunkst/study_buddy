import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:study_engine/study_engine.dart';

import '../../core/providers/database_provider.dart';
import '../../core/providers/focus_session_provider.dart';
import '../../core/theme/paper_extension.dart';
import '../../core/theme/paper_scaffold.dart';
import '../../core/theme/paper_widgets.dart';
import 'focus_providers.dart';

/// 专注时钟页：纸感卡片式计时 + 学习闭环信息（今日累计 + 会话知识点）。
///
/// 严格遵守 spec 硬约束：状态机仅 idle↔running→ended，不暂停、不拆时长、
/// 不引入目标时长/屏幕常亮。结束仍走弹框收集「这段时间做了什么」。
class FocusPage extends ConsumerWidget {
  const FocusPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(focusSessionProvider);
    final notifier = ref.read(focusSessionProvider.notifier);

    return PaperScaffold(
      appBar: AppBar(title: const Text('专注时钟')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _TimerCard(state: state, notifier: notifier, ref: ref),
              const SizedBox(height: 20),
              if (state.running)
                _CurrentSessionPanel(ref: ref)
              else
                _TodaySummaryPanel(ref: ref),
            ],
          ),
        ),
      ),
    );
  }
}

/// 主计时卡：纸感文章块，内嵌大号衬线计时 + 印章状态 + 开始/结束按钮。
class _TimerCard extends StatelessWidget {
  const _TimerCard({
    required this.state,
    required this.notifier,
    required this.ref,
  });

  final FocusSessionState state;
  final FocusSessionNotifier notifier;
  final WidgetRef ref;

  String get _clockText {
    final h = state.elapsed.inHours.toString().padLeft(2, '0');
    final m = (state.elapsed.inMinutes % 60).toString().padLeft(2, '0');
    final s = (state.elapsed.inSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final paper = theme.extension<PaperColors>();
    final accent = paper?.stampRed ?? theme.colorScheme.primary;

    return PaperArticle(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 文章块小标题：专注时刻
          const PaperArticleLabel(text: '专注时刻'),
          const SizedBox(height: 20),
          Center(child: PaperStampIcon(icon: Icons.timer_outlined, iconSize: 28)),
          const SizedBox(height: 12),
          // 大号衬线计时
          Center(
            child: Text(
              _clockText,
              style: theme.textTheme.displayLarge?.copyWith(
                fontFamily: 'NotoSerifSC',
                fontSize: 56,
                letterSpacing: 3,
                color: accent,
                fontFeatures: const [FontFeature.tabularFigures()],
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(height: 8),
          // 状态文案：running 「专注中…」 / idle 「准备好就开始吧」
          Center(
            child: Text(
              state.running ? '专注中…' : '准备好就开始吧',
              style: theme.textTheme.bodyMedium?.copyWith(
                fontFamily: 'NotoSerifSC',
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: 24),
          if (state.running)
            FilledButton.icon(
              icon: const Icon(Icons.stop),
              label: const Text('结束专注'),
              onPressed: () => _onStop(context),
            )
          else
            FilledButton.icon(
              icon: const Icon(Icons.play_arrow),
              label: const Text('开始专注'),
              onPressed: () => notifier.start(),
            ),
        ],
      ),
    );
  }

  /// 结束专注：弹框收集「这段时间做了什么」，写入会话摘要后再走完整 stop 流程。
  ///
  /// 仅 App 内按钮触发弹框；通知栏反向 onStopped 走裸 stop 不弹框（不打扰用户）。
  /// sessionId 取自当前 state（专注进行中非 null），用于在 stop 清空 state 前
  /// 把摘要写到正确的会话记录上。
  Future<void> _onStop(BuildContext context) async {
    final summary = await showDialog<String>(
      context: context,
      builder: (_) => const SummaryDialog(),
    );
    // 用户点「保存」且有非空文本 → 写库。跳过/取消/外部关闭(summary 为 null)不写。
    final text = summary?.trim() ?? '';
    if (state.sessionId != null && text.isNotEmpty) {
      final db = await ref.read(databaseProvider.future);
      final repo = FocusSessionRepository(db);
      await repo.setSummary(state.sessionId!, text);
    }
    await notifier.stop();
  }
}

/// 「这段时间做了什么」输入对话框。
///
/// 返回值：点「保存」返回输入文本（可能为空串，由调用方 trim 判断是否写入）；
/// 点「跳过」或点外部/返回键关闭（isDismissible 默认 true）返回 null。
/// 从私有 _SummaryDialog 提为公开 SummaryDialog，便于测试引用。
class SummaryDialog extends StatefulWidget {
  const SummaryDialog({super.key});

  @override
  State<SummaryDialog> createState() => _SummaryDialogState();
}

class _SummaryDialogState extends State<SummaryDialog> {
  final TextEditingController _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('这段时间做了什么？'),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        maxLines: 4,
        maxLength: 500,
        decoration: const InputDecoration(
          hintText: '例如：复习了极限的洛必达法则，做完了一套高数题',
          border: OutlineInputBorder(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('跳过'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_ctrl.text),
          child: const Text('保存'),
        ),
      ],
    );
  }
}

/// running 态：当前会话已关联知识点 chips。无关联时给引导文案。
class _CurrentSessionPanel extends StatelessWidget {
  const _CurrentSessionPanel({required this.ref});

  final WidgetRef ref;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final paper = theme.extension<PaperColors>();
    final topicsAsync = ref.watch(currentSessionTopicsProvider);

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLowest,
        border: Border.all(color: cs.outlineVariant),
        boxShadow: [
          BoxShadow(
            color: paper?.warmShadow ?? const Color(0x144C3C28),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: topicsAsync.when(
        loading: () => const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Center(
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ),
        error: (e, _) => Text(
          '知识点读取失败：$e',
          style: theme.textTheme.bodySmall?.copyWith(color: cs.error),
        ),
        data: (topics) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.lightbulb_outline,
                      size: 18, color: paper?.gold ?? cs.tertiary),
                  const SizedBox(width: 6),
                  Text(
                    topics.isEmpty
                        ? '本场已学'
                        : '本场已学 · ${topics.length}',
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontFamily: 'NotoSerifSC',
                      fontWeight: FontWeight.w700,
                      color: paper?.gold ?? cs.tertiary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (topics.isEmpty)
                Text(
                  '专注中在「问 AI」里沉淀的知识点会实时出现在这里',
                  style: theme.textTheme.bodySmall?.copyWith(
                    height: 1.6,
                    color: cs.onSurfaceVariant,
                  ),
                )
              else
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final t in topics)
                      _TopicChip(title: t.title),
                  ],
                ),
            ],
          );
        },
      ),
    );
  }
}

/// idle 态：今日累计专注摘要卡。激励用户开始专注。
class _TodaySummaryPanel extends StatelessWidget {
  const _TodaySummaryPanel({required this.ref});

  final WidgetRef ref;

  String _fmtDuration(int ms) {
    final h = ms ~/ 3600000;
    final m = (ms % 3600000) ~/ 60000;
    if (h == 0) return '$m 分钟';
    if (m == 0) return '$h 小时';
    return '$h 小时 $m 分';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final paper = theme.extension<PaperColors>();
    final summaryAsync = ref.watch(todayFocusSummaryProvider);

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLowest,
        border: Border.all(color: cs.outlineVariant),
        boxShadow: [
          BoxShadow(
            color: paper?.warmShadow ?? const Color(0x144C3C28),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: summaryAsync.when(
        loading: () => const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Center(
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ),
        error: (e, _) => Text(
          '今日专注读取失败：$e',
          style: theme.textTheme.bodySmall?.copyWith(color: cs.error),
        ),
        data: (summary) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.event_note_outlined,
                      size: 18, color: paper?.gold ?? cs.tertiary),
                  const SizedBox(width: 6),
                  Text(
                    '今日专注',
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontFamily: 'NotoSerifSC',
                      fontWeight: FontWeight.w700,
                      color: paper?.gold ?? cs.tertiary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    _fmtDuration(summary.totalMs),
                    style: theme.textTheme.headlineLarge?.copyWith(
                      fontFamily: 'NotoSerifSC',
                      fontWeight: FontWeight.w700,
                      color: cs.onSurface,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    summary.finishedCount > 0
                        ? '· 已完成 ${summary.finishedCount} 场'
                        : '',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              if (summary.isEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  '还没有专注记录，点上方「开始专注」进入第一场',
                  style: theme.textTheme.bodySmall?.copyWith(
                    height: 1.6,
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// 单个知识点胶囊：朱砂虚线边 + 标题，纸感印章味。
class _TopicChip extends StatelessWidget {
  const _TopicChip({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final accent = theme.extension<PaperColors>()?.stampRed ?? cs.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        border: Border.all(color: accent.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        title,
        style: theme.textTheme.labelMedium?.copyWith(
          color: cs.onSurface,
        ),
      ),
    );
  }
}