import 'dart:async';

import 'package:flutter/widgets.dart';

/// 依据积压(缓存)字符数计算本次 tick 应揭示的字符数。
///
/// `slack = 目标全文长度 - 已揭示字符数`,衡量 LLM 已被缓冲但尚未上屏的文本量。
/// 输出节奏随积压自适应:
///   - 积压 <= 0:缓存耗尽,暂停(0 字/拍)
///   - 积压 1~16:   低积压放缓,逐字输出(1 字/拍)
///   - 积压 17~80:  线性爬升(2~5 字/拍)
///   - 积压 >= 81:  高积压提速,快速追上缓存(6 字/拍)
///
/// 这样 SSE 大块到达时不会被整块弹出(摊平成分层渐入),流慢时又不会
/// 「追空-卡顿-再跳」,维持用户要求的动态平衡。
int typewriterStepForSlack(int slack) {
  if (slack <= 0) return 0;
  return (1 + (slack - 1) ~/ 16).clamp(1, 6);
}

/// 打字机渲染组件:接收流式累积的全文(充当「缓存」),按固定拍子逐字上屏,
/// 揭示速度由 [typewriterStepForSlack] 依据积压量动态调节。
///
/// 不感知流式状态(streamingText 累积方),只关心 [text] 全文与揭示进度:
///   - 文本增长(流式增量) → 从已揭示位置继续;
///   - 文本缩短(LLM 重试清空/轮次切换) → 重置从头重打;
///   - [active] 为 false(历史消息/已完成输出) → 立即显示全文,不走打字机。
///
/// 每拍只重建声明的部分文本,由 [builder] 决定最终渲染方式
/// (MarkdownLatex / SelectableText 等),组件自身不绑定任何展示层。
class TypewriterText extends StatefulWidget {
  const TypewriterText({
    super.key,
    required this.text,
    required this.builder,
    this.active = true,
    this.tick = const Duration(milliseconds: 40),
  });

  /// 目标全文(流式累积的「缓存」)。
  final String text;

  /// 渲染回调:收到已揭示的部分文本。
  final Widget Function(BuildContext context, String partial) builder;

  /// false 时立即显示全文(用于历史消息 / 已完成输出),不做打字动画。
  final bool active;

  /// 打字拍子周期(每拍按积压揭示若干字符)。
  final Duration tick;

  @override
  State<TypewriterText> createState() => _TypewriterTextState();
}

class _TypewriterTextState extends State<TypewriterText> {
  /// 已揭示字符数。
  int _shown = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _resync();
  }

  @override
  void didUpdateWidget(TypewriterText oldWidget) {
    super.didUpdateWidget(oldWidget);
    _resync();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// 依据当前 [widget] 协作目标同步揭示进度与定时器状态。
  void _resync() {
    if (!widget.active) {
      // 非动画态:立即全显,停掉定时器。
      _shown = widget.text.length;
      _stopTimer();
      return;
    }
    if (widget.text.length < _shown) {
      // 缓存被清空/缩短(如 LLM 重试):从新文本开头重新打字。
      _shown = 0;
    }
    if (_shown < widget.text.length) {
      _timer ??= Timer.periodic(widget.tick, (_) => _onTick());
    } else {
      _stopTimer();
    }
  }

  void _onTick() {
    if (!mounted) return;
    final step = typewriterStepForSlack(widget.text.length - _shown);
    if (step <= 0) {
      // 缓存耗尽且已揭示到末尾:停表,避免空转。
      if (_shown >= widget.text.length) _stopTimer();
      return;
    }
    setState(() {
      _shown = (_shown + step).clamp(0, widget.text.length);
      if (_shown >= widget.text.length) _stopTimer();
    });
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  Widget build(BuildContext context) {
    return widget.builder(context, widget.text.substring(0, _shown));
  }
}