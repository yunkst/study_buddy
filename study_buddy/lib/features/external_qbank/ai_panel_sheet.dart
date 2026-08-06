import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:study_engine/study_engine.dart';

import '../../core/providers/agent_session_provider.dart';
import '../../core/providers/webview_screenshot_provider.dart';

/// 弹出底部抽屉：截图预览 + 用户输入 + agent 流式回复。
///
/// 截图来自 [CapturedScreenshot]，纯内存持有；会话结束即释放（widget dispose）。
Future<void> showAiPanel(
  BuildContext context, {
  required CapturedScreenshot screenshot,
}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    isDismissible: true,
    enableDrag: true,
    builder: (_) => _AiPanelSheet(screenshot: screenshot),
  );
}

class _AiPanelSheet extends ConsumerStatefulWidget {
  const _AiPanelSheet({required this.screenshot});
  final CapturedScreenshot screenshot;

  @override
  ConsumerState<_AiPanelSheet> createState() => _AiPanelSheetState();
}

class _AiPanelSheetState extends ConsumerState<_AiPanelSheet> {
  final TextEditingController _inputCtrl = TextEditingController();
  final StringBuffer _aiText = StringBuffer();
  final List<String> _toolEvents = []; // 工具调用轨迹
  bool _busy = false;
  bool _saved = false; // save_topic 调用过
  String? _errorText;
  StreamSubscription<AgentEvent>? _sub;

  @override
  void dispose() {
    _sub?.cancel();
    _inputCtrl.dispose();
    // 显式置空让 GC 释放 bytes 与 base64 字符串
    super.dispose();
  }

  Future<void> _runAgent() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _errorText = null;
      _aiText.clear();
      _toolEvents.clear();
      _saved = false;
    });

    final userText = _inputCtrl.text.trim().isEmpty
        ? '分析这道题涉及的知识点'
        : _inputCtrl.text.trim();
    final messages = <ChatMessage>[
      ChatMessage(
        role: 'user',
        content: [
          TextPart(userText),
          ImageUrlPart(widget.screenshot.base64DataUri, detail: 'high'),
        ],
      ),
    ];

    try {
      final session = ref.read(agentSessionProvider);
      final stream = await session.run(messages);
      _sub = stream.listen(
        (event) {
          if (!mounted) return;
          setState(() {
            switch (event) {
              case AgentStartedEvent():
                // 已在 _busy 状态体现
                break;
              case TextDeltaEvent(:final delta):
                _aiText.write(delta);
                break;
              case ToolCallStartEvent(:final name):
                _toolEvents.add('→ 调用工具：$name');
                break;
              case ToolCallEndEvent(:final name, :final result):
                _toolEvents.add('← $name：$result');
                if (name == 'save_topic') _saved = true;
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
              case AgentDoneEvent():
                _busy = false;
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
          setState(() {
            _errorText = '$e';
            _busy = false;
          });
        },
        onDone: () {
          if (!mounted) return;
          setState(() => _busy = false);
        },
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorText = '$e';
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 12,
        bottom: mediaQuery.viewInsets.bottom + 16,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 顶部抓把手
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: Colors.grey.shade400,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            // 截图缩略图
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.memory(
                widget.screenshot.pngBytes,
                height: 120,
                fit: BoxFit.contain,
              ),
            ),
            const SizedBox(height: 12),
            // 用户输入
            TextField(
              controller: _inputCtrl,
              enabled: !_busy,
              decoration: const InputDecoration(
                labelText: '补充说明（可选）',
                hintText: '例如：解析思路',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              maxLines: 2,
            ),
            const SizedBox(height: 8),
            // 提交按钮
            FilledButton(
              onPressed: _busy ? null : _runAgent,
              child: Text(_busy ? '分析中...' : '开始分析'),
            ),
            const SizedBox(height: 16),
            // 错误展示
            if (_errorText != null)
              Container(
                padding: const EdgeInsets.all(8),
                color: Colors.red.shade50,
                child: Text(
                  _errorText!,
                  style: TextStyle(color: Colors.red.shade900),
                ),
              ),
            // 工具调用轨迹
            if (_toolEvents.isNotEmpty) ...[
              const Text('工具调用', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              ..._toolEvents.map(
                (e) => Text(e, style: const TextStyle(fontSize: 12)),
              ),
              if (_saved)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.green.shade50,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text(
                      '✓ 已保存到知识库',
                      style: TextStyle(color: Colors.green, fontSize: 12),
                    ),
                  ),
                ),
              const SizedBox(height: 12),
            ],
            // AI 回复文本
            if (_aiText.isNotEmpty) ...[
              const Text('AI 回复', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: SelectableText(_aiText.toString()),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
