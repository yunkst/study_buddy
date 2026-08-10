// 纸感学术 AI 面板（融合 master 多轮对话架构 × paper 纸感视觉）。
//
// 数据流（master 原样）：ChatSessionProvider 持有完整多轮历史（messages/streamingText/
// toolEvents/busy/error），send() 喂完整历史，抽屉关闭后 clear()。Riverpod 3.x 清空
// 时序保留：await 前捕获 container，关闭后 clear，不在 dispose 阶段改 provider state。
//
// 视觉（paper 纸感）：拍立得首图 / 「问」字用户气泡 / 知识点解析的 AI 回复 /
// ※ 工具轨迹 / 已归入知识库胶囊 / 朱砂左边框错误容器。主题 token 与 home_page /
// permission_guide_page 一致。
//
// 约束：engine 零改动；chat_session_provider.dart 零改动；AI 回复解析仅展示层
// （_buildAiTextSpan），不动消息字符串内容。
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:study_engine/study_engine.dart';

import '../../core/providers/chat_session_provider.dart';
import '../../core/providers/screenshot_provider.dart';
import '../../core/theme/dashed_border.dart';
import '../../core/theme/paper_extension.dart';

/// 弹出底部抽屉：消息列表 + 连续输入框 + 可选附图（纸感视觉）。
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
    final theme = Theme.of(context);
    // 纸感 token 由 AppTheme 注册；widget 测试用裸 MaterialApp 时可能缺失，
    // 此时降级为 colorScheme 兜底（视觉断言不依赖 paper）。
    final paper = theme.extension<PaperColors>();
    final colorScheme = theme.colorScheme;
    // AI 回复行样式：bodyLarge 基础上加 1.95 行高（bodyLarge 已是 NotoSansSC）。
    final aiBody = theme.textTheme.bodyLarge?.copyWith(height: 1.95);
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
            // 抓把手：outline 主题色。
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
                  ...state.messages.map(_buildMessageBubble),
                  // 流式文本（当前轮 LLM 正在输出）
                  if (state.streamingText.isNotEmpty)
                    _buildAssistantBubble(state.streamingText, state.toolEvents,
                        aiBody: aiBody),
                  // 首轮未发送时显示拍立得截图预览
                  if (!_firstSent && _pendingImage != null)
                    Center(
                      child: _Polaroid(
                        image: Image.memory(
                          _pendingImage!.pngBytes,
                          height: 100,
                          fit: BoxFit.contain,
                        ),
                        paper: paper,
                      ),
                    ),
                ],
              ),
            ),
            // 错误展示：纸感错误容器
            if (state.error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: _ErrorPanel(
                  text: state.error!,
                  colorScheme: colorScheme,
                  theme: theme,
                ),
              ),
            // 待附图预览（追问轮）：纸感小图 + 关闭
            if (_pendingImage != null && _firstSent)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        color: paper?.polaroidBg ?? colorScheme.surfaceContainerLowest,
                        border: Border.all(
                          color: colorScheme.outlineVariant,
                          width: 0.5,
                        ),
                      ),
                      child: Image.memory(_pendingImage!.pngBytes,
                          height: 44, fit: BoxFit.contain),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () => setState(() => _pendingImage = null),
                    ),
                  ],
                ),
              ),
            // 输入行：加图按钮 + 下划线输入框 + 墨黑提交按钮
            const SizedBox(height: 8),
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.add_photo_alternate_outlined),
                  onPressed: state.busy
                      ? null
                      : () {
                          // MVP:追问轮加图复用 initialScreenshot 的数据来源；
                          // 真实截图接入由悬浮窗阶段提供。
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

  Widget _buildMessageBubble(ChatMessage msg) {
    if (msg.role == 'user') {
      return _buildUserBubble(msg);
    }
    if (msg.role == 'assistant') {
      final text = msg.content is String ? msg.content as String : '';
      // 落库的 assistant 消息不再带工具轨迹（轨迹只属于当前流式轮）。
      return _buildAssistantBubble(text, const [], aiBody: null);
    }
    if (msg.role == 'tool') {
      final content = msg.content is String ? msg.content as String : '';
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '※ ',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                  ),
            ),
            Expanded(
              child: Text(
                content,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
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
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Align(
        alignment: Alignment.centerRight,
        child: _UserBubble(
          query: text,
          colorScheme: Theme.of(context).colorScheme,
          theme: Theme.of(context),
        ),
      ),
    );
  }

  /// AI 回复气泡：surfaceContainerLow 底 + bodyLarge height1.95 + 知识点行解析 +
  /// 当前轮工具轨迹（※ 装饰）。aiBody 仅流式轮与最终轮首渲染需要；落库消息用默认。
  Widget _buildAssistantBubble(
    String text,
    List<ToolEvent> toolEvents, {
    TextStyle? aiBody,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final body = aiBody ?? theme.textTheme.bodyLarge?.copyWith(height: 1.95);
    // save_topic 已完成 → 派生 _saved（不污染 ChatSessionState）。
    final saved = toolEvents.any(
      (e) => e.name == 'save_topic' && e.result != '进行中...',
    );
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerLow,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (text.isNotEmpty)
              SelectableText.rich(
                _buildAiTextSpan(text, body, colorScheme),
              ),
            if (toolEvents.isNotEmpty) ...[
              const SizedBox(height: 8),
              _ToolTrace(
                events: toolEvents,
                saved: saved,
                colorScheme: colorScheme,
                theme: theme,
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// AI 回复解析：以 `※` / `-` / `·` 开头的行加朱砂 ※ 前缀，其余原样输出。
  /// 仅展示层处理，不动消息字符串内容。
  /// 注意：最后一行不加换行，保证纯文本（如「这是分析」）能被 find.text 精确命中。
  TextSpan _buildAiTextSpan(
    String text,
    TextStyle? aiBody,
    ColorScheme colorScheme,
  ) {
    final lines = text.split('\n');
    final children = <InlineSpan>[];
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final trimmed = line.trimLeft();
      final isLast = i == lines.length - 1;
      final suffix = isLast ? '' : '\n';
      if (trimmed.startsWith('※') ||
          trimmed.startsWith('-') ||
          trimmed.startsWith('·')) {
        // 知识点行：朱砂 ※ 前缀 WidgetSpan + 缩进。
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
        children.add(TextSpan(text: '$trimmed$suffix', style: aiBody));
      } else {
        children.add(TextSpan(text: '$line$suffix', style: aiBody));
      }
    }
    return TextSpan(children: children);
  }
}

// ─────────────────────────────────────────────────────────────
// 私有 widget：拍立得截图
// ─────────────────────────────────────────────────────────────

/// 拍立得截图：白底 polaroidBg + 不对称 padding（底部留 caption）+ 倾斜 -1.5° +
/// 暖阴影 + 顶部图钉（朱砂圆）+ 斜体 caption「· 待分析 ·」。
class _Polaroid extends StatelessWidget {
  const _Polaroid({required this.image, this.paper});

  final Widget image;
  final PaperColors? paper; // 测试环境（裸 MaterialApp）缺失时用 colorScheme 兜底

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Transform.rotate(
      angle: -1.5 * math.pi / 180,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(10, 10, 10, 26),
            decoration: BoxDecoration(
              color: paper?.polaroidBg ?? colorScheme.surfaceContainerLowest,
              boxShadow: [
                BoxShadow(
                  color: paper?.warmShadow ?? colorScheme.shadow,
                  blurRadius: 8,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                image,
                const SizedBox(height: 4),
                Text(
                  '· 待分析 ·',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontStyle: FontStyle.italic,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
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
                    BoxShadow(
                        color: paper?.warmShadow ?? colorScheme.shadow,
                        blurRadius: 2),
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
// 私有 widget：用户气泡
// ─────────────────────────────────────────────────────────────

/// 用户气泡：note-user 风格，朱砂「问」字圆形章 + 提问文本（primaryContainer 底 +
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
          // 「问」字圆形章：朱砂底 + onPrimary 字 + labelSmall。
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

// ─────────────────────────────────────────────────────────────
// 私有 widget：工具调用轨迹
// ─────────────────────────────────────────────────────────────

/// 工具调用轨迹容器：surfaceContainerHigh 底 + titleSmall 标题 + ※ 装饰前缀。
/// events 为 master 的 [ToolEvent]（name/result），由调用方传入当前轮轨迹。
class _ToolTrace extends StatelessWidget {
  const _ToolTrace({
    required this.events,
    required this.saved,
    required this.colorScheme,
    required this.theme,
  });

  final List<ToolEvent> events;
  final bool saved;
  final ColorScheme colorScheme;
  final ThemeData theme;

  String _label(ToolEvent e) {
    switch (e.name) {
      case '·':
        return e.result; // 进度/压缩/重试等提示行
      default:
        return e.result == '进行中...' ? '${e.name} …' : '${e.name}：${e.result}';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHigh,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('工具调用', style: theme.textTheme.titleSmall),
          const SizedBox(height: 6),
          ...events.map(
            (e) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '※ ',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.primary,
                    ),
                  ),
                  Expanded(
                    child: Text(_label(e), style: theme.textTheme.bodySmall),
                  ),
                ],
              ),
            ),
          ),
          if (saved) ...[
            const SizedBox(height: 6),
            _SavedCapsule(colorScheme: colorScheme, theme: theme),
          ],
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// 私有 widget：已保存胶囊
// ─────────────────────────────────────────────────────────────

/// 已归入知识库胶囊：tertiaryContainer 底 + DashedBorder 虚线边 + ✓ + 短文本。
class _SavedCapsule extends StatelessWidget {
  const _SavedCapsule({required this.colorScheme, required this.theme});

  final ColorScheme colorScheme;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: colorScheme.tertiaryContainer,
      ),
      foregroundDecoration: ShapeDecoration(
        shape: DashedBorder(
          dash: 4,
          gap: 3,
          color: colorScheme.tertiary,
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '✓',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colorScheme.onTertiaryContainer,
            ),
          ),
          const SizedBox(width: 4),
          Text(
            '已归入知识库',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colorScheme.onTertiaryContainer,
            ),
          ),
        ],
      ),
    );
  }
}
