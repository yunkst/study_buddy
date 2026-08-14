// 学习伙伴 Onboarding:5 节纸感分页引导页。
// 前 4 节为通用 _OnboardingStep(印章序号 + 线稿插画 + 说明),教育高效学习方法
// (遇题即拆/对抗遗忘曲线/目标规划/专注复盘)并落到 App 功能怎么配合,
// 第 5 节为真实 _OnboardingStepForm(LLM 配置表单),完成时写库 + 写 prefs + 跳首页。
// 底部固定区 _BottomBar:跳过 / 圆点指示器 / 下一步·完成。
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:study_engine/study_engine.dart';

import '../../core/providers/database_provider.dart';
import '../../core/theme/dashed_border.dart';
import '../../core/theme/paper_extension.dart';
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
                    ordinal: '一', illustration: _StepArt.split,
                    title: '遇题即拆',
                    body: '别急着抄答案——先让 AI 把题目拆成一个个知识点，弄懂"考什么"比记住"答案是什么"更值钱。\n相册或浏览器分享图片到本 App，框选题目，AI 自动拆解知识点存入库。',
                  ),
                  _OnboardingStep(
                    ordinal: '二', illustration: _StepArt.forgettingCurve,
                    title: '对抗遗忘曲线',
                    body: '学过的东西 24 小时内忘掉一大半，这是大脑的规律，不是你不够努力。\n拆下的知识点会按遗忘曲线自动排期：每天打开"今日复习"，翻面回忆、如实评分，该复习的自然会再出现。',
                  ),
                  _OnboardingStep(
                    ordinal: '三', illustration: _StepArt.milestones,
                    title: '设定目标，AI 帮你规划',
                    body: '光有"想学好"不够，要有截止日期和检验点。\n报上考试日期，让 AI 拆出里程碑节点，再录测评分数，进步曲线看得见。',
                  ),
                  _OnboardingStep(
                    ordinal: '四', illustration: _StepArt.focusClock,
                    title: '专注时刻，记录努力的痕迹',
                    body: '学不进去往往是因为时间在不知不觉中流失。\n点开「开始专注」计时，专注中沉淀的知识点会实时出现；结束时记一句"这段时间做了什么"，学习日报帮你复盘——今天学了什么、明天补什么，每一分努力都有迹可循。',
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
        child: Text('时习 · 欢迎',
            style: theme.textTheme.displayLarge?.copyWith(fontSize: 22)),
      ),
    );
  }
}

/// 单页（前 4 页通用），第 5 页用 _OnboardingStepForm 替换。
class _OnboardingStep extends StatelessWidget {
  const _OnboardingStep({
    required this.ordinal,
    required this.illustration,
    required this.title,
    required this.body,
  });
  final String ordinal;
  final _StepArt illustration;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final paper = theme.extension<PaperColors>();
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      child: PaperArticle(
        child: Column(
          children: [
            PaperArticleLabel(text: title),
            const SizedBox(height: 16),
            Center(child: _OnboardingSeal(ordinal: ordinal)),
            const SizedBox(height: 16),
            SizedBox(
              width: 220,
              height: 120,
              child: CustomPaint(
                painter: _StepIllustrationPainter(
                  art: illustration,
                  // CustomPainter 无 context,色板在此取好传入。
                  inkRule: theme.colorScheme.outlineVariant,
                  inkAccent: theme.colorScheme.primary,
                  inkGold: paper?.gold ?? theme.colorScheme.tertiary,
                ),
                size: const Size(220, 120),
              ),
            ),
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

/// 引导页四幅线稿插画:每页图解本页学习方法。
enum _StepArt {
  /// 一 遇题即拆:拍立得题目卡,向右"拆"出 3 个小知识方块(虚线分隔)。
  split,

  /// 二 对抗遗忘曲线:下坠遗忘曲线 + 两次复习回升小尖峰,坐标轴细线。
  forgettingCurve,

  /// 三 设定目标:左→右时间线,3 个节点 + 终点小旗 + 上扬进步曲线。
  milestones,

  /// 四 专注时刻:圆形表盘 + 已走过的时间弧 + 下方横线日报。
  focusClock,
}

/// 线稿插画绘制器:细线稿(inkRule 浅棕)+ 强调线(inkAccent 印章红)+
/// 点睛(inkGold 提示金),与 DashedBorder/印章同源的纸感手绘风。
/// 逻辑画布固定 220x120(由 _OnboardingStep 的 SizedBox 保证)。
class _StepIllustrationPainter extends CustomPainter {
  const _StepIllustrationPainter({
    required this.art,
    required this.inkRule,
    required this.inkAccent,
    required this.inkGold,
  });

  final _StepArt art;

  /// 细线稿色(取 outlineVariant,与纸面分隔线同源)。
  final Color inkRule;

  /// 强调色(取 primary/印章红)。
  final Color inkAccent;

  /// 点睛色(取提示金)。
  final Color inkGold;

  @override
  void paint(Canvas canvas, Size size) {
    switch (art) {
      case _StepArt.split:
        _paintSplit(canvas, size);
      case _StepArt.forgettingCurve:
        _paintForgettingCurve(canvas, size);
      case _StepArt.milestones:
        _paintMilestones(canvas, size);
      case _StepArt.focusClock:
        _paintFocusClock(canvas, size);
    }
  }

  /// 沿路径画虚线(与 DashedBorder 同算法,简化版:仅支持直线段路径)。
  void _dashPath(Canvas canvas, Path path, Paint paint) {
    final metrics = path.computeMetrics();
    for (final metric in metrics) {
      double distance = 0;
      while (distance < metric.length) {
        final end = (distance + 4).clamp(0.0, metric.length);
        canvas.drawPath(metric.extractPath(distance, end), paint);
        distance += 7;
      }
    }
  }

  /// 一 遇题即拆:左侧拍立得题目卡(白底实线框 + 底部厚边 + 内部题面横线),
  /// 中间虚线"撕开"轨迹,右侧 3 个纵向堆叠的小知识方块(金边)。
  void _paintSplit(Canvas canvas, Size size) {
    final rule = Paint()
      ..color = inkRule
      ..strokeWidth = 1.4
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final accent = Paint()
      ..color = inkAccent
      ..strokeWidth = 1.8
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final gold = Paint()
      ..color = inkGold
      ..strokeWidth = 1.4
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final cardBg = Paint()
      ..color = inkRule.withValues(alpha: 0.06)
      ..style = PaintingStyle.fill;

    // 拍立得题目卡:主体 60x70 + 底部厚边(相纸留白),整体 -4° 微倾。
    canvas.save();
    final cardRect = const Rect.fromLTWH(18, 26, 60, 68);
    canvas.translate(cardRect.center.dx, cardRect.center.dy);
    canvas.rotate(-4 * 3.1415926 / 180);
    canvas.translate(-cardRect.center.dx, -cardRect.center.dy);
    canvas.drawRRect(
      RRect.fromRectAndRadius(cardRect, const Radius.circular(3)), cardBg);
    canvas.drawRRect(
      RRect.fromRectAndRadius(cardRect, const Radius.circular(3)), accent);
    // 底部厚边横线(拍立得下沿)。
    canvas.drawLine(
      Offset(cardRect.left, cardRect.bottom - 14),
      Offset(cardRect.right, cardRect.bottom - 14),
      accent,
    );
    // 题面横线(三行文字示意)。
    for (var i = 0; i < 3; i++) {
      final y = cardRect.top + 18 + i * 11.0;
      canvas.drawLine(
        Offset(cardRect.left + 9, y),
        Offset(cardRect.right - 9 - (i == 2 ? 16 : 0), y),
        rule,
      );
    }
    canvas.restore();

    // 中间虚线"拆开"轨迹:两条错位短虚线向右下。
    final tear = Path()
      ..moveTo(86, 38)
      ..lineTo(112, 46)
      ..moveTo(88, 84)
      ..lineTo(114, 74);
    _dashPath(canvas, tear, accent);

    // 右侧 3 个知识方块(18x18,纵向堆叠,金边实线,内一点)。
    for (var i = 0; i < 3; i++) {
      final rect = Rect.fromLTWH(140, 30.0 + i * 30, 18, 18);
      canvas.drawRect(rect, gold);
      canvas.drawCircle(rect.center, 1.6, gold..style = PaintingStyle.fill);
      gold.style = PaintingStyle.stroke;
      // 方块尾部短线(知识点入库示意)。
      canvas.drawLine(
        Offset(rect.right + 5, rect.center.dy),
        Offset(rect.right + 22, rect.center.dy),
        rule,
      );
    }
  }

  /// 二 对抗遗忘曲线:L 形坐标轴(细线)+ 无复习的下坠曲线(浅棕,趋近于零)+
  /// 两次复习尖峰(金色竖线 + 回升高点),复习后的下坠越来越缓。
  void _paintForgettingCurve(Canvas canvas, Size size) {
    final rule = Paint()
      ..color = inkRule
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final accent = Paint()
      ..color = inkAccent
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final gold = Paint()
      ..color = inkGold
      ..strokeWidth = 1.4
      ..style = PaintingStyle.stroke;

    // L 形坐标轴。
    canvas.drawLine(const Offset(24, 14), const Offset(24, 96), rule);
    canvas.drawLine(const Offset(24, 96), const Offset(204, 96), rule);

    // 无复习的遗忘曲线(指数下坠,浅棕虚线,趋近横轴)。
    final decay = Path()..moveTo(24, 24);
    for (var x = 0.0; x <= 180; x += 4) {
      final t = x / 180;
      final y = 24 + (96 - 28) * (1 - math.exp(-3.2 * t)); // 趋近 y=96-8
      decay.lineTo(24 + x, y);
    }
    _dashPath(canvas, decay, rule);

    // 复习后的记忆曲线(印章红实线):每次复习拉回高点,下坠坡度逐次变缓。
    final memory = Path()..moveTo(24, 24);
    void drop(double x0, double x1, double y0, double y1, double k) {
      for (var x = x0; x < x1; x += 3) {
        final t = (x - x0) / (x1 - x0);
        final y = y0 + (y1 - y0) * (1 - math.exp(-k * t)) / (1 - math.exp(-k));
        memory.lineTo(x, y);
      }
    }

    drop(24, 78, 24, 80, 3.0); // 第一次下坠
    memory.lineTo(78, 34); // 复习 1:拉回
    drop(78, 132, 34, 72, 2.6); // 第二次下坠(更缓)
    memory.lineTo(132, 42); // 复习 2:拉回
    drop(132, 200, 42, 64, 2.0); // 第三次下坠(更缓,保持高位)
    canvas.drawPath(memory, accent);

    // 两次复习的标记:金色竖虚线 + 曲线回升处小圆点。
    for (final (i, x) in [78.0, 132.0].indexed) {
      final mark = Path()
        ..moveTo(x, 96)
        ..lineTo(x, 104);
      _dashPath(canvas, mark, gold);
      final dot = Offset(x, i == 0 ? 34.0 : 42.0);
      canvas.drawCircle(dot, 2.0, gold..style = PaintingStyle.fill);
      gold.style = PaintingStyle.stroke;
    }
  }

  /// 三 设定目标:左→右时间线(细线)+ 3 个里程碑节点(空心圆,第二个金色填充)+
  /// 终点小旗(印章红)+ 上扬的进步曲线(金色,虚线升到旗杆高度)。
  void _paintMilestones(Canvas canvas, Size size) {
    final rule = Paint()
      ..color = inkRule
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final accent = Paint()
      ..color = inkAccent
      ..strokeWidth = 1.8
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final gold = Paint()
      ..color = inkGold
      ..strokeWidth = 1.6
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    // 时间线主轴(日期刻度短线)。
    canvas.drawLine(const Offset(24, 78), const Offset(196, 78), rule);
    for (final x in [56.0, 104.0, 152.0]) {
      canvas.drawLine(Offset(x, 74), Offset(x, 82), rule);
    }

    // 里程碑节点:空心圆(已达成第一个金填充,其余空心)。
    const nodes = [56.0, 104.0, 152.0];
    for (var i = 0; i < nodes.length; i++) {
      final c = Offset(nodes[i], 78);
      canvas.drawCircle(c, 5, i == 0 ? gold : rule);
      if (i == 0) {
        canvas.drawCircle(c, 1.8, gold..style = PaintingStyle.fill);
        gold.style = PaintingStyle.stroke;
      }
    }

    // 终点小旗:旗杆竖线 + 三角旗面。
    canvas.drawLine(const Offset(196, 78), const Offset(196, 34), accent);
    final flag = Path()
      ..moveTo(196, 34)
      ..lineTo(220 - 12, 41)
      ..lineTo(196, 48)
      ..close();
    canvas.drawPath(flag, accent..style = PaintingStyle.fill);
    accent.style = PaintingStyle.stroke;

    // 进步曲线:从第一个节点虚线上扬到旗杆。
    final rise = Path()..moveTo(56, 70);
    for (var x = 0.0; x <= 140; x += 4) {
      final t = x / 140;
      // 缓入加速上扬,终点到旗杆中部高度。
      final y = 70 - 34 * t * t;
      rise.lineTo(56 + x, y);
    }
    _dashPath(canvas, rise, gold);
  }

  /// 四 专注时刻:左侧圆形表盘(细线圈 + 刻度 + 印章红时间弧 + 指针)+
  /// 右侧日报(三条横线,首条金色粗线作标题)。
  void _paintFocusClock(Canvas canvas, Size size) {
    final rule = Paint()
      ..color = inkRule
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final accent = Paint()
      ..color = inkAccent
      ..strokeWidth = 2.2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final gold = Paint()
      ..color = inkGold
      ..strokeWidth = 1.4
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    // 表盘:圆心 (52,60) 半径 34。
    const center = Offset(52, 60);
    const radius = 34.0;
    canvas.drawCircle(center, radius, rule);
    // 12/3/6/9 点刻度。
    for (final angle in [0.0, 90.0, 180.0, 270.0]) {
      final rad = angle * 3.1415926 / 180;
      final outer = Offset(
        center.dx + radius * math.sin(rad),
        center.dy - radius * math.cos(rad),
      );
      final inner = Offset(
        center.dx + (radius - 6) * math.sin(rad),
        center.dy - (radius - 6) * math.cos(rad),
      );
      canvas.drawLine(inner, outer, rule);
    }

    // 已走过的时间弧:从 12 点顺时针 250°(印章红)。
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius - 3),
      -3.1415926 / 2, // 起始 12 点
      250 * 3.1415926 / 180,
      false,
      accent,
    );

    // 指针:指向弧的末端(250° 处)。
    final handRad = (-90 + 250) * 3.1415926 / 180;
    final handEnd = Offset(
      center.dx + (radius - 12) * math.cos(handRad),
      center.dy + (radius - 12) * math.sin(handRad),
    );
    canvas.drawLine(center, handEnd, accent);
    canvas.drawCircle(center, 2.2, accent..style = PaintingStyle.fill);
    accent.style = PaintingStyle.stroke;

    // 右侧日报:三条横线(首条金色稍粗作标题,后两条浅棕),左侧对齐。
    canvas.drawLine(const Offset(112, 44), const Offset(202, 44), gold);
    canvas.drawLine(const Offset(112, 64), const Offset(196, 64), rule);
    canvas.drawLine(const Offset(112, 84), const Offset(200, 84), rule);
    // 每条线前端一个小方点(日报条目示意)。
    for (final y in [44.0, 64.0, 84.0]) {
      canvas.drawRect(Rect.fromLTWH(106, y - 2, 4, 4),
          (y == 44 ? gold : rule)..style = PaintingStyle.fill);
      (y == 44 ? gold : rule).style = PaintingStyle.stroke;
    }
  }

  @override
  bool shouldRepaint(covariant _StepIllustrationPainter oldDelegate) =>
      art != oldDelegate.art ||
      inkRule != oldDelegate.inkRule ||
      inkAccent != oldDelegate.inkAccent ||
      inkGold != oldDelegate.inkGold;
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
