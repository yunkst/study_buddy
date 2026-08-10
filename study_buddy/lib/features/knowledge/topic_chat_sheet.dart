import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:study_engine/study_engine.dart';

import '../../core/providers/agent_session_provider.dart';
import '../../core/providers/knowledge_providers.dart';

/// 知识点深度交流抽屉。复用 ai_panel_sheet 的底部 Modal 模式,但多轮 + 持久化 + 上下文注入。
Future<void> showTopicChat(
  BuildContext context, {
  required int topicId,
  required String title,
}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    isDismissible: true,
    enableDrag: true,
    builder: (_) => _TopicChatSheet(topicId: topicId, title: title),
  );
}

class _TopicChatSheet extends ConsumerStatefulWidget {
  const _TopicChatSheet({required this.topicId, required this.title});
  final int topicId;
  final String title;
  @override
  ConsumerState<_TopicChatSheet> createState() => _TopicChatSheetState();
}

class _TopicChatSheetState extends ConsumerState<_TopicChatSheet> {
  final TextEditingController _inputCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();

  /// 渲染模型：历史消息 + 当轮气泡。每条是 [role, text] 或工具轨迹。
  final List<_ChatLine> _lines = [];
  final List<ChatMessage> _history = []; // 传给 AgentLoop 的全量历史
  StringBuffer? _pendingAi;
  bool _busy = false;
  bool _loadingHistory = true;
  String? _errorText;
  int? _sessionId;
  StreamSubscription<AgentEvent>? _sub;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final chatRepo = await ref.read(chatRepositoryProvider.future);
      final sessionId = await chatRepo.findOrCreateByTopic(widget.topicId, widget.title);
      final history = await chatRepo.listMessages(sessionId);
      if (!mounted) return;
      setState(() {
        _sessionId = sessionId;
        _loadingHistory = false;
        // 把历史铺成渲染行
        for (final m in history) {
          if (m.role == 'user') {
            _lines.add(_ChatLine.user(_textOf(m)));
          } else if (m.role == 'assistant' && m.toolCalls == null) {
            _lines.add(_ChatLine.ai(_textOf(m)));
          } else if (m.role == 'assistant' && m.toolCalls != null) {
            // 工具调用消息：只显示工具名轨迹,不铺 assistant 文本
            for (final tc in m.toolCalls!) {
              _lines.add(_ChatLine.tool('调用工具:${tc.name}'));
            }
          }
          _history.add(m);
        }
      });
      _scrollToBottom();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingHistory = false;
        _errorText = '加载会话失败:$e';
      });
    }
  }

  String _textOf(ChatMessage m) {
    final c = m.content;
    if (c is String) return c;
    return (c as List).whereType<TextPart>().map((p) => p.text).join('\n');
  }

  Future<void> _send() async {
    final text = _inputCtrl.text.trim();
    if (text.isEmpty || _busy) return;
    _inputCtrl.clear();
    final userMsg = ChatMessage(role: 'user', content: text);
    _history.add(userMsg);
    setState(() {
      _lines.add(_ChatLine.user(text));
      _busy = true;
      _errorText = null;
      _pendingAi = StringBuffer();
      _lines.add(_ChatLine.ai(''));
    });
    _scrollToBottom();

    try {
      final session = ref.read(agentSessionProvider);
      final topicCtx = await _buildTopicContext();
      final stream = await session.run(_history, context: topicCtx);
      if (!mounted) return;
      _sub = stream.listen(
        (event) {
          if (!mounted) return;
          setState(() {
            switch (event) {
              case AgentStartedEvent():
                break;
              case TextDeltaEvent(:final delta):
                _pendingAi!.write(delta);
                _lines.last = _ChatLine.ai(_pendingAi.toString());
                break;
              case ToolCallStartEvent(:final name):
                _lines.add(_ChatLine.tool('→ 调用工具:$name'));
                break;
              case ToolCallEndEvent(:final name):
                if (name == 'update_topic') {
                  _lines.add(const _ChatLine.note('✎ 已更新答案'));
                } else if (name == 'link_topics') {
                  _lines.add(const _ChatLine.note('✓ 已建关联'));
                }
                break;
              case AgentDoneEvent():
                _busy = false;
                // 同步快照 aiText（此时 _pendingAi 尚未被下一轮重置），
                // 避免 fire-and-forget 的 _persistRound 在两次 await 后
                // 读到被第二轮重置的 buffer。
                final aiText = _pendingAi?.toString() ?? '';
                _persistRound(userMsg, aiText);
                break;
              case AgentErrorEvent(:final message):
                _errorText = message;
                _busy = false;
                break;
              case ToolProgressEvent():
              case AgentRoundEndEvent():
                // 工具轮中间通知：UI 已用 ToolCallStart/End 渲染轨迹，
                // AgentDone 才是持久化点，无需额外处理。
              case CompactionEvent():
              case RetryEvent():
                break;
            }
          });
          if (event is TextDeltaEvent) _scrollToBottom();
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
        // 失败则移除占位的空 AI 气泡
        if (_lines.isNotEmpty && _lines.last.role == 'ai' && _lines.last.text.isEmpty) {
          _lines.removeLast();
        }
      });
    }
  }

  /// 持久化本轮 user + assistant 消息（简化版：不落 tool_calls）。
  ///
  /// [aiText] 由调用方在 AgentDone 同步快照后传入（消除读 _pendingAi 的
  /// 竞态）。assistant 消息同步入 [_history]，消除下一轮 _send 读
  /// _history 时缺本轮回答的窗口。
  Future<void> _persistRound(ChatMessage userMsg, String aiText) async {
    final sid = _sessionId;
    if (sid == null) return;
    final aiMsg = ChatMessage(role: 'assistant', content: aiText);
    _history.add(aiMsg); // 同步入 history，先于 await
    try {
      final chatRepo = await ref.read(chatRepositoryProvider.future);
      await chatRepo.addMessage(sid, userMsg);
      await chatRepo.addMessage(sid, aiMsg);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存对话失败:$e')),
      );
    }
  }

  /// 构建当前知识点上下文注入：await 拉取完整快照（详情页缓存已热,通常秒回）。
  Future<AgentScenarioContext> _buildTopicContext() async {
    final detail = await ref.read(topicDetailProvider(widget.topicId).future);
    return AgentScenarioContext(extra: {
      'current_topic': {
        'id': widget.topicId,
        'title': widget.title,
        'path': detail.path.join('/'),
        'question': detail.topic.question,
        'summary': detail.topic.summary,
        'edges': detail.edges
            .map((e) => {'type': e.type, 'other_id': e.otherId, 'other_title': e.otherTitle})
            .toList(),
      }
    });
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final sheetHeight = mediaQuery.size.height * 0.6;
    return Padding(
      padding: EdgeInsets.only(bottom: mediaQuery.viewInsets.bottom),
      child: SizedBox(
        height: sheetHeight,
        child: Column(
          children: [
            // 抓把手
            Center(child: Container(
              width: 40, height: 4, margin: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: Colors.grey.shade400, borderRadius: BorderRadius.circular(2)),
            )),
            // 当前知识点标题条
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: Colors.grey.shade100,
              child: Row(children: [
                const Icon(Icons.menu_book, size: 16),
                const SizedBox(width: 6),
                Expanded(child: Text(widget.title, style: const TextStyle(fontWeight: FontWeight.bold), overflow: TextOverflow.ellipsis)),
              ]),
            ),
            const Divider(height: 1),
            // 消息列表
            Expanded(child: _loadingHistory
              ? const Center(child: CircularProgressIndicator())
              : ListView.builder(
                  controller: _scrollCtrl,
                  padding: const EdgeInsets.all(12),
                  itemCount: _lines.length,
                  itemBuilder: (_, i) => _buildLine(_lines[i]),
                )),
            if (_errorText != null)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                color: Colors.red.shade50,
                child: Text(_errorText!, style: TextStyle(color: Colors.red.shade900, fontSize: 12)),
              ),
            // 输入区
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              child: Row(children: [
                Expanded(child: TextField(
                  controller: _inputCtrl,
                  enabled: !_busy,
                  minLines: 1, maxLines: 3,
                  decoration: const InputDecoration(
                    hintText: '就当前知识点继续追问...',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _send(),
                )),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _busy ? null : _send,
                  child: Text(_busy ? '思考中' : '发送'),
                ),
              ]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLine(_ChatLine line) {
    final isUser = line.role == 'user';
    final isNote = line.role == 'note';
    final isTool = line.role == 'tool';
    if (isTool || isNote) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Text(line.text,
            style: TextStyle(fontSize: 11,
                color: isNote ? Colors.green.shade700 : Colors.grey.shade600)),
      );
    }
    final bg = isUser ? Colors.green.shade100 : Colors.grey.shade200;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(12),
        ),
        child: SelectableText(line.text),
      ),
    );
  }
}

/// 渲染行模型。
class _ChatLine {
  final String role; // 'user' | 'ai' | 'tool' | 'note'
  final String text;
  const _ChatLine(this.role, this.text);
  const _ChatLine.user(String t) : this('user', t);
  const _ChatLine.ai(String t) : this('ai', t);
  const _ChatLine.tool(String t) : this('tool', t);
  const _ChatLine.note(String t) : this('note', t);
}
