import 'package:flutter/material.dart';

import '../../core/providers/share_card_provider.dart';

// 固定亮色「日光纸」色值（取自 app_colors.dart / paper_extension.dart 的 light 常量）。
// 顶层私有常量：卡片所有子 widget 共用，确保导出图不受系统暗色模式影响。
const _ink = Color(0xFF2C2620);
const _inkSoft = Color(0xFF6B5D4F);
const _paper = Color(0xFFF5F0E6);
const _paperHi = Color(0xFFFAF6EC);
const _stampRed = Color(0xFFB8472D);
const _rule = Color(0xFFE8DFCA);
const _shadow = Color(0x144C3C28);

/// 分享卡（D 手账日记风）：把今日学习数据渲染成竖版纸感卡片，供 RepaintBoundary 截图。
///
/// **导出稳定性**：卡片用**固定亮色「日光纸」硬编码色值**，不读 Theme/PaperColors，
/// 保证 `captureWidget` 导出的 PNG 风格稳定，不受用户当前暗色模式影响。
/// （PaperColors 亮/暗各一套，toImage 只截 boundary 内，故须硬编码。）
///
/// [summary] 为 AI「今日收获」总结（或模板）；loading 时调用方传 null 显示占位。
/// 尺寸固定 360×480（3:4），配合 pixelRatio=3 → 1080×1440，适配小红书清晰度。
class ShareCardWidget extends StatelessWidget {
  const ShareCardWidget({
    super.key,
    required this.data,
    this.summary,
    this.summaryLoading = false,
    required this.date,
  });

  final ShareCardData data;
  final String? summary;
  final bool summaryLoading;
  final DateTime date;

  static const double width = 360;
  static const double height = 480;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: height,
      child: Material(
        type: MaterialType.transparency,
        child: DecoratedBox(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [_paperHi, _paper],
            ),
          ),
          child: Stack(
            children: [
              // 横线纸纹底（自绘，不依赖全局 PaperScaffold）。
              Positioned.fill(
                child: CustomPaint(painter: _RuledPainter(spacing: 30, color: _rule)),
              ),
              // 内容层。
              Padding(
                padding: const EdgeInsets.fromLTRB(28, 26, 28, 60),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _Header(date: date),
                    const SizedBox(height: 10),
                    _IntroLine(summary: summary, loading: summaryLoading),
                    const SizedBox(height: 8),
                    _Entry(icon: '⏱', label: '今日专注', value: '${data.focusMinutes} 分钟'),
                    _Entry(icon: '📚', label: '学了', value: '${data.topics.length} 个知识点'),
                    _Entry(icon: '🔄', label: '还有', value: '${data.dueNow} 道待复习'),
                    const SizedBox(height: 14),
                    _PinnedBlock(streak: data.streak, totalHours: data.totalFocusMinutes ~/ 60),
                  ],
                ),
              ),
              // 话题标签 + DONE 印章。
              Positioned(
                left: 28,
                bottom: 22,
                child: Text(
                  '#学习打卡 #StudyBuddy',
                  style: TextStyle(
                    fontSize: 12,
                    color: _inkSoft,
                    fontFamily: 'NotoSansSC',
                  ),
                ),
              ),
              Positioned(
                right: 26,
                bottom: 20,
                child: Transform.rotate(
                  angle: -0.08,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                    decoration: BoxDecoration(
                      border: Border.all(color: _stampRed, width: 1.5),
                    ),
                    child: const Text(
                      'DONE',
                      style: TextStyle(
                        fontSize: 11,
                        color: _stampRed,
                        letterSpacing: 2,
                        fontFamily: 'NotoSansSC',
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.date});
  final DateTime date;

  String get _weekday {
    const cn = ['星期一', '星期二', '星期三', '星期四', '星期五', '星期六', '星期日'];
    return cn[date.weekday - 1];
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text(
              '✏ 今日学习',
              style: TextStyle(
                fontSize: 19,
                color: _ink,
                fontWeight: FontWeight.w700,
                fontFamily: 'NotoSerifSC',
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          '${date.year} 年 ${date.month} 月 ${date.day} 日 · $_weekday',
          style: TextStyle(fontSize: 11, color: _inkSoft, fontFamily: 'NotoSansSC'),
        ),
      ],
    );
  }
}

class _IntroLine extends StatelessWidget {
  const _IntroLine({required this.summary, required this.loading});
  final String? summary;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final text = loading
        ? '正在写今日小结…'
        : (summary?.trim().isNotEmpty == true ? summary!.trim() : '今天学得很充实 ✓');
    return Text(
      text,
      style: TextStyle(fontSize: 14.5, color: _ink, fontFamily: 'NotoSansSC', height: 1.5),
    );
  }
}

class _Entry extends StatelessWidget {
  const _Entry({required this.icon, required this.label, required this.value});
  final String icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(icon, style: const TextStyle(fontSize: 15)),
          const SizedBox(width: 8),
          Text('$label ', style: TextStyle(fontSize: 14.5, color: _ink, fontFamily: 'NotoSansSC')),
          Text(
            value,
            style: TextStyle(
              fontSize: 15,
              color: _ink,
              fontWeight: FontWeight.w700,
              fontFamily: 'NotoSerifSC',
            ),
          ),
        ],
      ),
    );
  }
}

class _PinnedBlock extends StatelessWidget {
  const _PinnedBlock({required this.streak, required this.totalHours});
  final int streak;
  final int totalHours;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0x14B8472D), // 朱砂红 8% 底
        border: Border(left: BorderSide(color: _stampRed, width: 3)),
        boxShadow: const [BoxShadow(color: _shadow, blurRadius: 0, offset: Offset(2, 2))],
      ),
      child: Column(
        children: [
          _PinnedRow(emoji: '🔥', label: '连续打卡', value: '$streak 天'),
          const SizedBox(height: 8),
          _PinnedRow(emoji: '⭐', label: '累计坚持', value: '$totalHours 小时'),
        ],
      ),
    );
  }
}

class _PinnedRow extends StatelessWidget {
  const _PinnedRow({required this.emoji, required this.label, required this.value});
  final String emoji;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text('$emoji $label', style: TextStyle(fontSize: 14, color: _ink, fontFamily: 'NotoSansSC')),
        Text(
          value,
          style: TextStyle(
            fontSize: 18,
            color: _stampRed,
            fontWeight: FontWeight.w700,
            fontFamily: 'NotoSerifSC',
          ),
        ),
      ],
    );
  }
}

/// 卡片内部横线纸纹画笔（复刻 paper_scaffold 的 _RuleLinesPainter，因其为私有不可复用）。
class _RuledPainter extends CustomPainter {
  const _RuledPainter({required this.spacing, required this.color});
  final double spacing;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 0.5
      ..style = PaintingStyle.stroke;
    double y = spacing;
    while (y < size.height) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
      y += spacing;
    }
  }

  @override
  bool shouldRepaint(covariant _RuledPainter old) =>
      spacing != old.spacing || color != old.color;
}