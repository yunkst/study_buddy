// ask_user 输入区语义：两个 sheet（ai_panel_sheet、plan_chat_sheet）共享的
// pendingAsk 切换逻辑，避免双写。所有判断基于三态：
//   - busy：agent 正在跑（输入框禁用）
//   - pendingAsk：agent 挂起等用户作答
//   - firstSent：sheet 自身的轮次状态（仅影响首轮 vs 追问的默认发送文案）
//
// 调用方传入当前状态得到视图属性（enabled/hint/buttonIconKey/defaultSendLabel）。
// busy 与 pendingAsk 优先时的固定文案（"分析中..."/"提交答案" 等）由 helper
// 提供，避免双写；默认发送文案由调用方提供（ai_panel_sheet 用 "发送"/"开始分析"，
// plan_chat_sheet 用 "发送"）。
library;

import 'package:study_engine/study_engine.dart';

/// ask_user 输入区的统一语义判定。两个 sheet 共用，避免分支逻辑双写。
class AskUserInputSemantics {
  const AskUserInputSemantics({
    required this.busy,
    required this.pendingAsk,
    required this.firstSent,
  });

  /// agent 是否正在跑（控制整张 sheet 忙态）。
  final bool busy;

  /// 当前等待用户作答的提问（null 表示无挂起）。
  final AskUserRequest? pendingAsk;

  /// 是否已发出过至少一轮消息。仅影响默认发送文案（首轮 vs 追问）——
  /// helper 仅消费此字段决定 firstSent/firstSent+ 的差别由调用方提供。
  final bool firstSent;

  /// 输入框是否可编辑：busy 禁用；pendingAsk 含选项时禁用（须点上方选项）。
  bool get inputEnabled {
    if (busy) return false;
    if (pendingAsk != null && !pendingAsk!.isFreeInput) return false;
    return true;
  }

  /// 输入框 hint。
  String get hint {
    if (pendingAsk != null) {
      return pendingAsk!.isFreeInput ? '请输入答案' : '请选择上方选项';
    }
    return firstSent ? '追问...' : '补充说明（可选）';
  }

  /// 提交按钮图标 key（用于图标选择）：
  ///   'busy' → 沙漏, 'check' → 对勾, 'note' → 笔记图标。
  String get buttonIconKey {
    if (busy) return 'busy';
    if (pendingAsk != null) return 'check';
    return 'note';
  }

  /// busy 状态的按钮文案（agent 跑中）。默认 "分析中..."，plan sheet 传 "思考中..."。
  String busyLabel({String? override}) => override ?? '分析中...';

  /// pendingAsk 自由输入模式：提交答案。
  String get freeInputSubmitLabel => '提交答案';

  /// pendingAsk 含选项模式：请选择上方选项（按钮禁用态仍展示该文案）。
  String get optionSelectLabel => '请选择上方选项';

  /// 首轮（_firstSent=false）的默认发送文案。
  String get firstSendLabel => '开始分析';

  /// 追问轮（_firstSent=true）的默认发送文案。
  String get followUpSendLabel => '追问...';

  /// 正常对话（非 busy 非 pendingAsk）的提交按钮文案，由调用方根据上下文选其一。
  String defaultSendLabel() => firstSent ? followUpSendLabel : firstSendLabel;

  /// 当前按钮应展示的完整文案。busy/pendingAsk 优先，否则用调用方的默认发送文案。
  ///
  /// [planSheetOverride]：正常对话态的文案（plan 统一 "发送"；ai 用首轮/追问）。
  /// [busyOverride]：busy 态文案（plan "思考中..."；ai 默认 "分析中..."）。
  String currentButtonLabel({String? planSheetOverride, String? busyOverride}) {
    if (busy) return busyLabel(override: busyOverride);
    if (pendingAsk != null) {
      return pendingAsk!.isFreeInput ? freeInputSubmitLabel : optionSelectLabel;
    }
    // plan_chat_sheet 没有首轮/追问差异，统一 "发送"。
    return planSheetOverride ?? defaultSendLabel();
  }
}