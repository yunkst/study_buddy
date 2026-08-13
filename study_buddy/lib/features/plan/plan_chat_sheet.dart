import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:study_engine/study_engine.dart';

import '../../core/providers/plan_provider.dart';
import '../../core/widgets/ask_user_card.dart';
import '../../core/widgets/ask_user_input_semantics.dart';

/// 弹出计划 AI 对话。planId 为空=新建模式，非空=调整模式。
/// 新建模式下 create_plan 成功后跳转 /plan/:id。
Future<void> showPlanChat(BuildContext context, {int? planId, String? planName}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    isDismissible: true,
    enableDrag: true,
    builder: (_) => _PlanChatSheet(planId: planId, planName: planName),
  );
}

class _PlanChatSheet extends ConsumerStatefulWidget {
  const _PlanChatSheet({this.planId, this.planName});
  final int? planId;
  final String? planName;

  @override
  ConsumerState<_PlanChatSheet> createState() => _PlanChatSheetState();
}

class _PlanChatSheetState extends ConsumerState<_PlanChatSheet> {
  final TextEditingController _inputCtrl = TextEditingController();
  final StringBuffer _aiText = StringBuffer();
  final List<String> _toolEvents = [];
  final List<ChatMessage> _history = [];
  bool _busy = false;
  String? _errorText;
  int? _createdPlanId;
  StreamSubscription<AgentEvent>? _sub;
  /// 当前轮 agent 会话句柄，供 _respondToAsk 回灌 ask_user 答案。
  AgentSessionHandle? _handle;
  /// 当前等待用户作答的提问（agent 挂起时非空）。
  AskUserRequest? _pendingAsk;

  @override
  void dispose() {
    _handle?.abortAskUser('会话已关闭');
    _handle = null;
    _sub?.cancel();
    _inputCtrl.dispose();
    super.dispose();
  }

  Future<void> _runAgent() async {
    if (_busy) return;
    final userText = _inputCtrl.text.trim();
    if (userText.isEmpty) return;
    // 当前用户消息先入历史，多轮对话保留完整上下文
    _history.add(ChatMessage(role: 'user', content: userText));
    setState(() {
      _busy = true;
      _errorText = null;
      _aiText.clear();
      _toolEvents.clear();
    });

    final messages = [..._history];
    try {
      // 启动新流前取消旧订阅，避免流事件串进同一 _aiText/_toolEvents 与双重 onDone
      await _sub?.cancel();
      final session = ref.read(planSessionProvider);
      final handle = await session.run(messages, planId: widget.planId, today: DateTime.now());
      _handle = handle;
      if (!mounted) return;
      _sub = handle.stream.listen(
        (event) {
          if (!mounted) return;
          setState(() {
            switch (event) {
              case TextDeltaEvent(:final delta):
                _aiText.write(delta);
                break;
              case ToolCallStartEvent(:final name):
                _toolEvents.add('→ 调用工具：$name');
                break;
              case ToolCallEndEvent(:final name, :final result):
                _toolEvents.add('← $name：$result');
                // 新建模式下捕获 create_plan 返回的 plan_id
                if (widget.planId == null && name == 'create_plan') {
                  final m = RegExp(r'"plan_id":\s*(\d+)').firstMatch(result);
                  if (m != null) _createdPlanId = int.tryParse(m.group(1)!);
                }
                break;
              case ToolProgressEvent(:final progress):
                _toolEvents.add('· $progress');
                break;
              case CompactionEvent():
                _toolEvents.add('· 上下文已压缩');
                break;
              case RetryEvent(:final attempt):
                // 与 chat_session_provider 对齐：重试前丢弃本轮已部分累积的流式文本，
                // 避免新旧 LLM 输出拼接出乱码。
                _aiText.clear();
                _toolEvents.add('· 重试第 $attempt 次');
                break;
              case AgentStartedEvent():
                // no-op：保持 _busy=true，"思考中"禁用态在 Done/Error 前持续有效
                break;
              case AskUserRequestedEvent(:final request):
                // agent 挂起等用户作答：渲染提问卡片（不清 _busy，仍"思考中"）。
                _pendingAsk = request;
                break;
              case AskUserAnsweredEvent(:final answer):
                _toolEvents.add('← ask_user 已作答：$answer');
                break;
              case AgentDoneEvent(:final finalText):
                // finalText==null 表示达到 maxRounds。
                // 非 null 时把纯文本轮的最终回答并入 _history，供下一轮多轮引用
                // （对比 chat_session_provider 同类分支；否则连续两轮 user 消息，AI 丢上下文）。
                if (finalText != null) {
                  _history.add(ChatMessage(role: 'assistant', content: finalText));
                }
                _pendingAsk = null;
                _busy = false;
                // maxRounds 截断时给用户可见提示，与 chat 侧的 _ErrorPanel 对齐。
                if (finalText == null) {
                  _errorText = '已达最大轮数';
                }
                break;
              case AgentRoundEndEvent(:final newMessages):
                // 本轮新增的 assistant/tool 消息全部并入历史，供下一轮引用
                _history.addAll(newMessages);
                // 与 chat_session_provider 对齐：每轮 streamingText 独立，不跨轮累积。
                _aiText.clear();
                break;
              case AgentErrorEvent(:final message):
                _pendingAsk = null;
                _errorText = message;
                _busy = false;
                break;
            }
          });
        },
        onError: (e) {
          if (!mounted) return;
          _handle = null;
          setState(() { _pendingAsk = null; _errorText = '$e'; _busy = false; });
        },
        onDone: () {
          if (!mounted) return;
          _handle = null;
          setState(() { _pendingAsk = null; _busy = false; });
          // 新建成功 → 跳详情页
          if (_createdPlanId != null) {
            Navigator.of(context).pop();
            context.go('/plan/$_createdPlanId');
          }
        },
      );
    } catch (e) {
      if (!mounted) return;
      setState(() { _pendingAsk = null; _errorText = '$e'; _busy = false; });
    }
  }

  /// 回答当前待处理的 ask_user 提问：答案经 handle 回灌挂起的 agent。
  void _respondToAsk(String answer) {
    if (_pendingAsk == null) return;
    _handle?.completeAskUser(answer);
    setState(() => _pendingAsk = null);
  }

  // 输入区语义判定委托给共享的 AskUserInputSemantics（与 ai_panel_sheet 共用），
  // 仅保留 sheet 自身的提交行为（_onInputSubmit）。

  /// 构造当前输入区语义。plan 无首轮/追问差异，firstSent 固定 true。
  AskUserInputSemantics get _semantics => AskUserInputSemantics(
        busy: _busy,
        pendingAsk: _pendingAsk,
        firstSent: true,
      );

  /// 提交：pendingAsk 自由输入模式回灌答案；否则正常发起 agent 一轮。
  void _onInputSubmit() {
    if (_busy) return;
    if (_pendingAsk != null) {
      if (_pendingAsk!.isFreeInput) {
        final text = _inputCtrl.text.trim();
        if (text.isEmpty) return;
        _inputCtrl.clear();
        _respondToAsk(text);
      }
      return;
    }
    _runAgent();
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    return Padding(
      padding: EdgeInsets.only(left: 16, right: 16, top: 12, bottom: mq.viewInsets.bottom + 16),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(width: 40, height: 4, margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(color: Colors.grey.shade400, borderRadius: BorderRadius.circular(2))),
            ),
            Text(
              widget.planName != null ? '正在调整：${widget.planName}' : '新建学习计划',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              widget.planId == null
                  ? '告诉我考试日期、内容、目标、每日时长和当前水平，我帮你拆计划。'
                  : '说说你想怎么调整，比如"把第 3 个节点提前一周"。',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 12),
            Builder(builder: (ctx) {
              final s = _semantics;
              return TextField(
                controller: _inputCtrl,
                enabled: s.inputEnabled,
                decoration: InputDecoration(
                  labelText: _pendingAsk != null
                      ? (_pendingAsk!.isFreeInput ? '输入答案' : '请选择上方选项')
                      : '消息',
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
                maxLines: 2,
                onSubmitted: (_) => _onInputSubmit(),
              );
            }),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: _semantics.inputEnabled ? _onInputSubmit : null,
              child: Text(_semantics.currentButtonLabel(
                planSheetOverride: '发送',
                busyOverride: '思考中...',
              )),
            ),
            // ask_user 提问卡片：agent 挂起等用户作答。
            if (_pendingAsk != null) ...[
              const SizedBox(height: 12),
              AskUserCard(request: _pendingAsk!, onSubmit: _respondToAsk),
            ],
            const SizedBox(height: 16),
            if (_errorText != null)
              Container(
                padding: const EdgeInsets.all(8),
                color: Colors.red.shade50,
                child: Text(_errorText!, style: TextStyle(color: Colors.red.shade900, fontSize: 12)),
              ),
            if (_toolEvents.isNotEmpty) ...[
              const Text('工具调用', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
              const SizedBox(height: 4),
              ..._toolEvents.map((e) => Text(e, style: const TextStyle(fontSize: 12))),
              const SizedBox(height: 12),
            ],
            if (_aiText.isNotEmpty) ...[
              const Text('AI 回复', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
              const SizedBox(height: 4),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: Colors.grey.shade100, borderRadius: BorderRadius.circular(6)),
                child: SelectableText(_aiText.toString()),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
