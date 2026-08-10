import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:study_engine/study_engine.dart';

import '../../core/providers/chat_session_provider.dart';
import '../../core/providers/screenshot_provider.dart';

/// 弹出底部抽屉：消息列表 + 连续输入框 + 可选附图。
///
/// 截图来自 [CapturedScreenshot]，纯内存持有；会话结束即释放。
/// 抽屉关闭后通过 [ProviderScope.containerOf] 取容器清空会话（纯内存），
/// 避免在 widget dispose 阶段修改 provider state（Riverpod 3.x 禁止）。
Future<void> showAiPanel(
  BuildContext context, {
  required CapturedScreenshot screenshot,
}) async {
  // 在 await 前捕获容器：抽屉关闭后清空会话（纯内存），不依赖 context.mounted。
  // 若在 await 后再 containerOf，页面可能已 pop，context 已 unmounted，
  // 会话（含截图 bytes）将无法清空。
  final container = ProviderScope.containerOf(context, listen: false);
  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    isDismissible: true,
    enableDrag: true,
    builder: (_) => _AiPanelSheet(initialScreenshot: screenshot),
  );
  // 抽屉关闭后清空会话（纯内存）。container 在 await 前捕获，
  // 不依赖 context.mounted。
  container.read(currentChatProvider.notifier).clear();
}

class _AiPanelSheet extends ConsumerStatefulWidget {
  const _AiPanelSheet({required this.initialScreenshot});
  final CapturedScreenshot initialScreenshot;

  @override
  ConsumerState<_AiPanelSheet> createState() => _AiPanelSheetState();
}

class _AiPanelSheetState extends ConsumerState<_AiPanelSheet> {
  final TextEditingController _inputCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  CapturedScreenshot? _pendingImage; // 追问轮待附加的图
  bool _firstSent = false;

  @override
  void initState() {
    super.initState();
    // 首轮：用入口截图作为首条消息的图。但不自动发送——等用户点"开始分析"。
    _pendingImage = widget.initialScreenshot;
    // 监听会话状态变化：仅在有新消息/流式增量时滚动到底部。
    // 不在 build() 里调 addPostFrameCallback——那会导致每帧都调度新帧，
    // pumpAndSettle 永不 settle。
    ref.listenManual(currentChatProvider, (prev, next) {
      if (prev == null) return;
      final grew = next.messages.length != prev.messages.length ||
          next.streamingText.length != prev.streamingText.length;
      if (grew) _scheduleScrollToBottom();
    });
  }

  void _scheduleScrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
      }
    });
  }

  @override
  void dispose() {
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    // 会话清空由 showAiPanel 在抽屉关闭后统一处理（dispose 阶段不可改 provider state）。
    super.dispose();
  }

  Future<void> _send() async {
    final text = _inputCtrl.text;
    final image = _pendingImage;
    _inputCtrl.clear();
    setState(() {
      _pendingImage = null;
      _firstSent = true;
    });
    await ref.read(currentChatProvider.notifier).send(text, image: image);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(currentChatProvider);
    final mediaQuery = MediaQuery.of(context);

    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 12,
        bottom: mediaQuery.viewInsets.bottom + 16,
      ),
      child: SizedBox(
        height: mediaQuery.size.height * 0.7,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 抓把手
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
            // 消息列表
            Expanded(
              child: ListView(
                controller: _scrollCtrl,
                children: [
                  ...state.messages.map(_buildMessageBubble),
                  // 流式文本（当前轮 LLM 正在输出）
                  if (state.streamingText.isNotEmpty)
                    _buildAssistantBubble(state.streamingText, state.toolEvents),
                  // 首轮未发送时显示截图预览
                  if (!_firstSent && _pendingImage != null)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.memory(
                        _pendingImage!.pngBytes,
                        height: 120,
                        fit: BoxFit.contain,
                      ),
                    ),
                ],
              ),
            ),
            // 错误展示
            if (state.error != null)
              Container(
                margin: const EdgeInsets.only(top: 8),
                padding: const EdgeInsets.all(8),
                color: Colors.red.shade50,
                child: Text(state.error!, style: TextStyle(color: Colors.red.shade900)),
              ),
            // 待附图预览（追问轮）
            if (_pendingImage != null && _firstSent)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: Image.memory(_pendingImage!.pngBytes,
                          height: 48, fit: BoxFit.contain),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () => setState(() => _pendingImage = null),
                    ),
                  ],
                ),
              ),
            // 输入行
            const SizedBox(height: 8),
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.add_photo_alternate_outlined),
                  onPressed: state.busy
                      ? null
                      : () {
                          // MVP:追问轮加图复用 initialScreenshot 的数据来源；
                          // 真实截图接入由悬浮窗阶段提供。此处仅占位禁用或提示。
                          // （本任务不实现真实选图,留待截图入口统一）
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('加图功能待截图入口接入')),
                          );
                        },
                ),
                Expanded(
                  child: TextField(
                    controller: _inputCtrl,
                    enabled: !state.busy,
                    decoration: InputDecoration(
                      hintText: _firstSent ? '追问...' : '补充说明（可选）',
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                    onSubmitted: (_) => _send(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: state.busy ? null : _send,
                  child: Text(state.busy ? '分析中...' : (_firstSent ? '发送' : '开始分析')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMessageBubble(ChatMessage msg) {
    if (msg.role == 'user') {
      return _buildUserBubble(msg);
    }
    if (msg.role == 'assistant') {
      return _buildAssistantBubble(
          msg.content is String ? msg.content as String : '',
          const []);
    }
    if (msg.role == 'tool') {
      final content = msg.content is String ? msg.content as String : '';
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Text('🔧 $content',
            style: const TextStyle(fontSize: 12, color: Colors.grey)),
      );
    }
    return const SizedBox.shrink();
  }

  Widget _buildUserBubble(ChatMessage msg) {
    final text = msg.content is String
        ? msg.content as String
        : (msg.content as List<ContentPart>)
            .whereType<TextPart>()
            .map((t) => t.text)
            .join();
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.deepPurple.shade100,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(text),
      ),
    );
  }

  Widget _buildAssistantBubble(String text, List<ToolEvent> toolEvents) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.grey.shade100,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (text.isNotEmpty) SelectableText(text),
            ...toolEvents.map((e) => Text('${e.name}: ${e.result}',
                style: const TextStyle(fontSize: 12, color: Colors.grey))),
          ],
        ),
      ),
    );
  }
}
