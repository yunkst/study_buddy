import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:study_engine/study_engine.dart';

import '../../core/providers/plan_provider.dart';

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

  @override
  void dispose() {
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
      final stream = await session.run(messages, planId: widget.planId, today: DateTime.now());
      if (!mounted) return;
      _sub = stream.listen(
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
                _toolEvents.add('· 重试第 $attempt 次');
                break;
              case AgentStartedEvent():
                // no-op：保持 _busy=true，"思考中"禁用态在 Done/Error 前持续有效
                break;
              case AgentDoneEvent():
                _busy = false;
                break;
              case AgentRoundEndEvent(:final newMessages):
                // 本轮新增的 assistant/tool 消息全部并入历史，供下一轮引用
                _history.addAll(newMessages);
                break;
              case AgentErrorEvent(:final message):
                _errorText = message;
                _busy = false;
                break;
            }
          });
        },
        onError: (e) {
          if (!mounted) return;
          setState(() { _errorText = '$e'; _busy = false; });
        },
        onDone: () {
          if (!mounted) return;
          setState(() => _busy = false);
          // 新建成功 → 跳详情页
          if (_createdPlanId != null) {
            Navigator.of(context).pop();
            context.go('/plan/$_createdPlanId');
          }
        },
      );
    } catch (e) {
      if (!mounted) return;
      setState(() { _errorText = '$e'; _busy = false; });
    }
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
            TextField(
              controller: _inputCtrl,
              enabled: !_busy,
              decoration: const InputDecoration(
                labelText: '消息',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              maxLines: 2,
              onSubmitted: (_) => _runAgent(),
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: _busy ? null : _runAgent,
              child: Text(_busy ? '思考中...' : '发送'),
            ),
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
