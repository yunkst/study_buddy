// 复习会话：翻面卡 + 四档 FSRS 评分。
//
// 队列取 reviewQueueProvider（今日到期 ≤ kDailyReviewCap(20) 张），进度推进
// 走 reviewSessionProvider。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:study_engine/study_engine.dart';

import '../../core/theme/paper_extension.dart';
import '../../core/theme/paper_scaffold.dart';
import '../../core/widgets/markdown_latex.dart';
import 'review_providers.dart';

/// 复习会话页：今日到期卡片的翻面背诵 + 四档 FSRS 评分。
class ReviewSessionPage extends ConsumerStatefulWidget {
  const ReviewSessionPage({super.key});

  @override
  ConsumerState<ReviewSessionPage> createState() => _ReviewSessionPageState();
}

class _ReviewSessionPageState extends ConsumerState<ReviewSessionPage> {
  bool _flipped = false;

  @override
  Widget build(BuildContext context) {
    final queueAsync = ref.watch(reviewQueueProvider);
    final session = ref.watch(reviewSessionProvider);

    return PaperScaffold(
      appBar: AppBar(title: const Text('复习')),
      body: queueAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, st) => _CenteredMessage(
          message: '复习队列加载失败：$err',
          onBack: () => context.go('/today'),
        ),
        data: (queue) {
          if (queue.isEmpty) {
            return _CenteredMessage(
              message: '今日无待复习',
              onBack: () => context.go('/today'),
            );
          }
          // 队列非空但会话自然 done（next 越界）→ 完成视图。
          // done 时 index 停在最后一张（0 基），已复习张数 = index+1。
          if (session.done || session.index >= queue.length) {
            return _DoneView(
              reviewed: (session.index + 1).clamp(0, queue.length),
              onBack: () => context.go('/today'),
            );
          }
          return _buildCard(context, queue, session.index);
        },
      ),
    );
  }

  /// 当前卡：进度条 + 翻卡 + 四档评分。
  Widget _buildCard(
    BuildContext context,
    List<TopicSchedule> queue,
    int index,
  ) {
    final schedule = queue[index];
    final topicAsync = ref.watch(reviewTopicProvider(schedule.topicId));
    final total = queue.length;
    final theme = Theme.of(context);
    final paper = theme.extension<PaperColors>();
    final accent = paper?.stampRed ?? theme.colorScheme.primary;

    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 顶部进度：第 N / M 张 + 细进度条。
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '第 ${index + 1} / $total 张',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontFamily: 'NotoSerifSC',
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                LinearProgressIndicator(
                  value: (index + 1) / total,
                  minHeight: 6,
                  borderRadius: BorderRadius.circular(4),
                  color: accent,
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          // 卡片主体（可滚动，容纳 Markdown/LaTeX）。
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: topicAsync.when(
                loading: () => const Center(
                  child: Padding(
                    padding: EdgeInsets.all(40),
                    child: CircularProgressIndicator(),
                  ),
                ),
                error: (err, st) => _TopicErrorView(
                  message: '知识点加载失败：$err',
                  onSkip: () => _skipInvalid(total),
                ),
                data: (topic) {
                  if (topic == null) {
                    return _TopicErrorView(
                      message: '该知识点已被删除',
                      onSkip: () => _skipInvalid(total),
                    );
                  }
                  return _CardView(
                    flipped: _flipped,
                    accent: accent,
                    question: topic.question,
                    summary: topic.summary,
                    onFlip: () => setState(() => _flipped = !_flipped),
                    onRate: (r) => _rate(schedule, r, total),
                    predict: (r) => _predict(schedule, r),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 各评分下的预估下次间隔（用于按钮下小字提示）。
  ///
  /// forgot 显示“30 分钟内”（kForgotInterval 固定 30min）；其余按
  /// `round(S * growth * (10-D)/9)` 天，clamp ≥1。
  String _predict(TopicSchedule schedule, Rating rating) {
    if (rating == Rating.forgot) return '30 分钟内';
    final growth = switch (rating) {
      Rating.hard => kGrowthHard,
      Rating.good => kGrowthGood,
      Rating.easy => kGrowthEasy,
      Rating.forgot => 1.0, // 上面已分流，此处仅保类型完备
    };
    final days = (schedule.stability * growth * (10 - schedule.difficulty) / 9)
        .round();
    return '约 ${days.clamp(1, 1 << 30)} 天';
  }

  /// 点评分：gradeAndUpsert；false（新卡额度用尽）保持当前卡并提示。
  Future<void> _rate(TopicSchedule schedule, Rating rating, int total) async {
    final ok = await gradeAndUpsert(
      ref,
      schedule: schedule,
      rating: rating,
      now: DateTime.now(),
    );
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('今日新卡额度已用完，明天再来')));
      return;
    }
    // 评分成功：翻回正面 + 推进下一张（越界即 done）。
    setState(() => _flipped = false);
    ref.read(reviewSessionProvider.notifier).next(total);
  }

  /// 跳过非法卡（topic 缺失 / 加载失败）：提示 + 推进。
  void _skipInvalid(int total) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('已跳过无效卡')));
    setState(() => _flipped = false);
    ref.read(reviewSessionProvider.notifier).next(total);
  }
}

/// 单张翻卡：正面 question + 提示，点击翻面显示 summary + 四档按钮。
class _CardView extends StatelessWidget {
  const _CardView({
    required this.flipped,
    required this.accent,
    required this.question,
    required this.summary,
    required this.onFlip,
    required this.onRate,
    required this.predict,
  });

  final bool flipped;
  final Color accent;
  final String question;
  final String summary;
  final VoidCallback onFlip;
  final ValueChanged<Rating> onRate;
  final String Function(Rating) predict;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Card(
      elevation: 1,
      clipBehavior: Clip.antiAlias,
      color: cs.surface,
      margin: EdgeInsets.zero,
      child: GestureDetector(
        onTap: onFlip,
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!flipped) ...[
                MarkdownLatex(data: question),
                const SizedBox(height: 16),
                Text(
                  '点击翻面看答案',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                    fontFamily: 'NotoSerifSC',
                  ),
                ),
                const SizedBox(height: 20),
              ] else ...[
                MarkdownLatex(data: summary),
                const SizedBox(height: 16),
                _RatingRow(accent: accent, onRate: onRate, predict: predict),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 四档评分行：忘了 / 困难 / 良好 / 简单，各带预估下次间隔小字。
class _RatingRow extends StatelessWidget {
  const _RatingRow({
    required this.accent,
    required this.onRate,
    required this.predict,
  });

  final Color accent;
  final ValueChanged<Rating> onRate;
  final String Function(Rating) predict;

  static const _labels = <Rating, String>{
    Rating.forgot: '忘了',
    Rating.hard: '困难',
    Rating.good: '良好',
    Rating.easy: '简单',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Row(
      children: [
        for (final r in Rating.values)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: Column(
                children: [
                  FilledButton.tonal(
                    onPressed: () => onRate(r),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(40),
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                    ),
                    child: Text(
                      _labels[r]!,
                      style: const TextStyle(fontFamily: 'NotoSerifSC'),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    predict(r),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// 居中提示视图：通用错误/空态。
class _CenteredMessage extends StatelessWidget {
  const _CenteredMessage({required this.message, required this.onBack});

  final String message;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(message, style: theme.textTheme.titleMedium),
          const SizedBox(height: 16),
          FilledButton.tonal(
            onPressed: onBack,
            child: const Text(
              '返回',
              style: TextStyle(fontFamily: 'NotoSerifSC'),
            ),
          ),
        ],
      ),
    );
  }
}

/// 完成视图：显示本次已复习张数。
class _DoneView extends StatelessWidget {
  const _DoneView({required this.reviewed, required this.onBack});

  final int reviewed;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('今日复习 $reviewed 张已完成', style: theme.textTheme.titleMedium),
          const SizedBox(height: 16),
          FilledButton.tonal(onPressed: onBack, child: const Text('返回')),
        ],
      ),
    );
  }
}

/// 题目加载失败/已删除视图：提示 + 跳过按钮。
class _TopicErrorView extends StatelessWidget {
  const _TopicErrorView({required this.message, required this.onSkip});

  final String message;
  final VoidCallback onSkip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        const SizedBox(height: 24),
        Text(
          message,
          style: theme.textTheme.bodyMedium,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 12),
        FilledButton.tonal(
          onPressed: onSkip,
          child: const Text(
            '跳过此卡',
            style: TextStyle(fontFamily: 'NotoSerifSC'),
          ),
        ),
      ],
    );
  }
}
