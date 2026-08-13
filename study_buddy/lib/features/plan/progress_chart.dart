import 'package:flutter/material.dart';
import 'package:study_engine/study_engine.dart';

/// 进步曲线：分数折线 + 目标虚线。CustomPainter 手绘，不引第三方图表库。
class ProgressChart extends StatelessWidget {
  const ProgressChart({
    super.key,
    required this.assessments,
    this.targetScore,
  });

  final List<Assessment> assessments;
  final int? targetScore;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final scored = assessments.where((a) => a.score != null).toList();
    if (scored.isEmpty) {
      return Container(
        height: 160,
        alignment: Alignment.center,
        child: Text('还没有可量化的测评记录\n记一次测评看进步曲线吧', textAlign: TextAlign.center, style: TextStyle(color: cs.onSurfaceVariant)),
      );
    }
    return SizedBox(
      height: 160,
      child: CustomPaint(
        size: Size.infinite,
        painter: _ChartPainter(scored: scored, targetScore: targetScore, scheme: cs),
      ),
    );
  }
}

class _ChartPainter extends CustomPainter {
  _ChartPainter({required this.scored, required this.targetScore, required this.scheme});
  final List<Assessment> scored;
  final int? targetScore;
  final ColorScheme scheme;

  @override
  void paint(Canvas canvas, Size size) {
    final scores = scored.map((a) => a.score!).toList();
    final minScore = scores.reduce((a, b) => a < b ? a : b);
    final maxScore = scores.reduce((a, b) => a > b ? a : b);
    var lo = minScore.toDouble();
    var hi = maxScore.toDouble();
    if (targetScore != null) {
      lo = lo < targetScore! ? lo : targetScore!.toDouble();
      hi = hi > targetScore! ? hi : targetScore!.toDouble();
    }
    // 留 10% 边距避免顶底贴边
    final span = (hi - lo) == 0 ? 1.0 : (hi - lo) * 1.2;
    final center = (hi + lo) / 2;
    lo = center - span / 2;
    hi = center + span / 2;

    final padL = 40.0, padR = 12.0, padT = 12.0, padB = 24.0;
    final w = size.width - padL - padR;
    final h = size.height - padT - padB;

    double x(int i) => padL + (scored.length == 1 ? w / 2 : w * i / (scored.length - 1));
    double y(int score) => padT + h * (1 - (score - lo) / (hi - lo));

    // 目标虚线
    if (targetScore != null) {
      final ty = y(targetScore!);
      final dashPaint = Paint()
        ..color = scheme.primary.withValues(alpha: 0.5)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1;
      const dashW = 5.0, gap = 4.0;
      var dx = padL;
      while (dx < size.width - padR) {
        canvas.drawLine(Offset(dx, ty), Offset(dx + dashW, ty), dashPaint);
        dx += dashW + gap;
      }
      final tp = TextPainter(text: TextSpan(text: '目标 $targetScore', style: TextStyle(fontSize: 10, color: scheme.primary)), textDirection: TextDirection.ltr);
      tp.layout();
      tp.paint(canvas, Offset(size.width - padR - tp.width - 2, ty - tp.height - 2));
    }

    // 折线
    final linePaint = Paint()
      ..color = scheme.primary
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final path = Path();
    for (var i = 0; i < scored.length; i++) {
      final p = Offset(x(i), y(scores[i]));
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
      // 数据点
      canvas.drawCircle(p, 3, Paint()..color = scheme.primary);
    }
    canvas.drawPath(path, linePaint);

    // 日期标签（首尾）
    final labelStyle = TextStyle(fontSize: 9, color: scheme.onSurfaceVariant);
    for (final i in [0, scored.length - 1]) {
      final a = scored[i];
      final label = '${a.assessedAt.month}/${a.assessedAt.day}';
      final tp = TextPainter(text: TextSpan(text: label, style: labelStyle), textDirection: TextDirection.ltr);
      tp.layout();
      tp.paint(canvas, Offset(x(i) - tp.width / 2, size.height - padB + 4));
    }
  }

  @override
  bool shouldRepaint(covariant _ChartPainter old) =>
      old.scored != scored || old.targetScore != targetScore || old.scheme != scheme;
}
