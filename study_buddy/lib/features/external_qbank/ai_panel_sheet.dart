// 纸感学术 AI 面板：消息列表多轮对话（拍立得截图 + 用户气泡 + 工具轨迹 + AI 回复）。
//
// 视觉参照 `design-preview/02-paper.html` 的 `.polaroid` / `.note-user` /
// `.saved-mark` / `.ai-note` / `.input-line` / `.btn-quill`。
// 主题 token 用法与 home_page / permission_guide_page 一致。
//
// 多轮架构（spec §3）：状态在 currentChatProvider，本文件只做渲染 + 输入。
// 截图纯内存，随会话释放；抽屉关闭后经 ProviderScope.containerOf 清空。
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:study_engine/study_engine.dart';

import '../../core/providers/chat_session_provider.dart';
import '../../core/providers/screenshot_provider.dart';
import '../../core/theme/paper_extension.dart';

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
  final container = ProviderScope.containerOf(context, listen: false);
  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    isDismissible: true,
    enableDrag: true,
    builder: (_) => _AiPanelSheet(initialScreenshot: screenshot),
  );
  // 抽屉关闭后清空会话（纯内存）。
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
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    // AI 回复行样式：bodyLarge 基础上加 1.95 行高，保留衬线感。
    final aiBody = theme.textTheme.bodyLarge?.copyWith(height: 1.95);
    // 纸感扩展兜底：未装配 PaperColors 的上下文（如 widget 测试裸 MaterialApp）
    // 退回亮色日光纸，避免 null 崩溃。
    final paper = theme.extension<PaperColors>() ?? PaperColors.light;

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
            // 顶部抓把手：outline 主题色（硬编码 grey 已替换）。
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: colorScheme.outline,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            // 消息列表
            Expanded(
              child: ListView(
                controller: _scrollCtrl,
                children: [
                  ...state.messages.map((m) => _buildMessage(m, theme, aiBody)),
                  // 流式文本（当前轮 LLM 正在输出）
                  if (state.streamingText.isNotEmpty)
                    _AiNote(
                      text: state.streamingText,
                      toolEvents: state.toolEvents,
                      aiBody: aiBody,
                      colorScheme: colorScheme,
                      theme: theme,
                    ),
                  // 首轮未发送时显示拍立得截图预览
                  if (!_firstSent && _pendingImage != null)
                    _Polaroid(
                      image: Image.memory(
                        _pendingImage!.pngBytes,
                        height: 100,
                        fit: BoxFit.contain,
                      ),
                      paper: paper,
                    ),
                ],
              ),
            ),
            // 错误展示：errorContainer 底 + 朱砂左边框。
            if (state.error != null) ...[
              const SizedBox(height: 8),
              _ErrorPanel(
                text: state.error!,
                colorScheme: colorScheme,
                theme: theme,
              ),
            ],
            // 待附图预览（追问轮）：拍立得缩略 + 移除按钮。
            if (_pendingImage != null && _firstSent) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  _Polaroid(
                    image: Image.memory(
                      _pendingImage!.pngBytes,
                      height: 48,
                      fit: BoxFit.contain,
                    ),
                    paper: paper,
                    compact: true,
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => setState(() => _pendingImage = null),
                  ),
                ],
              ),
            ],
            // 输入行：btn-quill（羽毛笔 icon）
            const SizedBox(height: 8),
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.add_photo_alternate_outlined),
                  onPressed: state.busy
                      ? null
                      : () {
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
                FilledButton.icon(
                  onPressed: state.busy ? null : _send,
                  icon: Icon(
                    state.busy ? Icons.hourglass_top : Icons.edit_note,
                    size: 18,
                  ),
                  label: Text(state.busy
                      ? '分析中...'
                      : (_firstSent ? '发送' : '开始分析')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 按消息角色分派渲染：user → 用户气泡；assistant → AI note；tool → 工具轨迹。
  Widget _buildMessage(ChatMessage msg, ThemeData theme, TextStyle? aiBody) {
    if (msg.role == 'user') {
      final text = _extractText(msg);
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: _UserBubble(
          query: text.isEmpty ? '（附图分析）' : text,
          colorScheme: theme.colorScheme,
          theme: theme,
        ),
      );
    }
    if (msg.role == 'assistant') {
      final text = _extractText(msg);
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: _AiNote(
          text: text,
          toolEvents: const [],
          aiBody: aiBody,
          colorScheme: theme.colorScheme,
          theme: theme,
        ),
      );
    }
    if (msg.role == 'tool') {
      final content = _extractText(msg);
      return _ToolTraceLine(
        line: '← $content',
        colorScheme: theme.colorScheme,
        theme: theme,
      );
    }
    return const SizedBox.shrink();
  }

  /// 从 ChatMessage.content 抽文本（String 直取；List 取 TextPart 拼接）。
  String _extractText(ChatMessage msg) {
    final c = msg.content;
    if (c is String) return c;
    if (c is List<ContentPart>) {
      return c.whereType<TextPart>().map((t) => t.text).join();
    }
    return '';
  }
}

// ─────────────────────────────────────────────────────────────
// 私有 widget：拍立得截图
// ─────────────────────────────────────────────────────────────

/// 拍立得截图：白底 polaroidBg + 不对称 padding（底部留 caption）+ 倾斜 -1.5° +
/// 暖阴影 + 顶部图钉（朱砂圆）+ 斜体 caption。
///
/// [compact] 为追问轮缩略预览：去掉倾斜与 caption，缩小 padding。
class _Polaroid extends StatelessWidget {
  const _Polaroid({required this.image, required this.paper, this.compact = false});

  final Widget image;
  final PaperColors paper;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final core = Container(
      padding: compact
          ? const EdgeInsets.all(6)
          : const EdgeInsets.fromLTRB(10, 10, 10, 26),
      decoration: BoxDecoration(
        color: paper.polaroidBg,
        boxShadow: [
          BoxShadow(
            color: paper.warmShadow,
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          image,
          if (!compact) ...[
            const SizedBox(height: 4),
            Text(
              '· 待分析 ·',
              style: theme.textTheme.bodySmall?.copyWith(
                fontStyle: FontStyle.italic,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
    if (compact) return core;
    return Transform.rotate(
      angle: -1.5 * math.pi / 180,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          core,
          // 顶部图钉：朱砂圆，居中悬浮在拍立得上沿。
          Positioned(
            top: -6,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(color: paper.warmShadow, blurRadius: 2),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// 私有 widget：用户气泡（note-user）
// ─────────────────────────────────────────────────────────────

/// 用户气泡：朱砂「问」字圆形章 + 提问文本（primaryContainer 底 +
/// 朱砂左边框 3px + 斜体 bodyMedium）。
class _UserBubble extends StatelessWidget {
  const _UserBubble({
    required this.query,
    required this.colorScheme,
    required this.theme,
  });

  final String query;
  final ColorScheme colorScheme;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer,
        border: Border(
          left: BorderSide(color: colorScheme.primary, width: 3),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: colorScheme.primary,
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text(
                '问',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: colorScheme.onPrimary,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              query,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// 私有 widget：AI 回复（ai-note）
// ─────────────────────────────────────────────────────────────

/// AI 回复容器：surfaceContainerLow 底 + bodyLarge height1.95 + 知识点行解析。
///
/// [toolEvents] 为当前轮流式工具轨迹（仅流式气泡传入；历史 assistant 消息传空）。
class _AiNote extends StatelessWidget {
  const _AiNote({
    required this.text,
    required this.toolEvents,
    required this.aiBody,
    required this.colorScheme,
    required this.theme,
  });

  final String text;
  final List<ToolEvent> toolEvents;
  final TextStyle? aiBody;
  final ColorScheme colorScheme;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 工具轨迹（当前轮流式期显示）
          ...toolEvents.map((e) => _ToolTraceLine(
                line: '${e.name}: ${e.result}',
                colorScheme: colorScheme,
                theme: theme,
              )),
          if (text.isNotEmpty) ...[
            if (toolEvents.isNotEmpty) const SizedBox(height: 6),
            SelectableText.rich(
              _buildAiTextSpan(text, aiBody, colorScheme),
            ),
          ],
        ],
      ),
    );
  }

  /// AI 回复解析：以 `※` / `-` / `·` 开头的行加朱砂 ※ 前缀，其余原样输出。
  /// 仅展示层处理，不动 text 字符串内容。
  TextSpan _buildAiTextSpan(
    String text,
    TextStyle? aiBody,
    ColorScheme colorScheme,
  ) {
    final lines = text.split('\n');
    final children = <InlineSpan>[];
    for (final line in lines) {
      final trimmed = line.trimLeft();
      if (trimmed.startsWith('※') ||
          trimmed.startsWith('-') ||
          trimmed.startsWith('·')) {
        children.add(WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Text(
              '※',
              style: TextStyle(color: colorScheme.primary, fontSize: 14),
            ),
          ),
        ));
        children.add(TextSpan(text: '$trimmed\n', style: aiBody));
      } else {
        children.add(TextSpan(text: '$line\n', style: aiBody));
      }
    }
    return TextSpan(children: children);
  }
}

// ─────────────────────────────────────────────────────────────
// 私有 widget：工具轨迹单行
// ─────────────────────────────────────────────────────────────

/// 工具调用轨迹单行：※ 装饰前缀 + bodySmall 小字灰。
/// 用于 tool 消息与流式工具事件，统一小字灰风格。
class _ToolTraceLine extends StatelessWidget {
  const _ToolTraceLine({
    required this.line,
    required this.colorScheme,
    required this.theme,
  });

  final String line;
  final ColorScheme colorScheme;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Text(
              '※',
              style: TextStyle(color: colorScheme.primary, fontSize: 12),
            ),
          ),
          Expanded(
            child: Text(
              line,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// 私有 widget：错误展示
// ─────────────────────────────────────────────────────────────

/// 错误容器：errorContainer 底 + 朱砂左边框 3px + onErrorContainer 文本。
class _ErrorPanel extends StatelessWidget {
  const _ErrorPanel({
    required this.text,
    required this.colorScheme,
    required this.theme,
  });

  final String text;
  final ColorScheme colorScheme;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: colorScheme.errorContainer,
        border: Border(
          left: BorderSide(color: colorScheme.primary, width: 3),
        ),
      ),
      child: Text(
        text,
        style: theme.textTheme.bodySmall?.copyWith(
          color: colorScheme.onErrorContainer,
        ),
      ),
    );
  }
}
