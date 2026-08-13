// 纸感学术 AI 对话页（全屏）：消息列表多轮对话（拍立得截图 + 用户气泡 + 工具轨迹 + AI 回复）。
//
// 由路由 `/ai` 承载（顶层 GoRoute，root navigator 承载 → 全屏盖住底部导航）。
// 进入方式：今日页「问 AI」入口 / 知识点详情页「问 AI 深度交流」/ 分享冷启动带图。
//
// 多轮架构（spec §3）：状态在 currentChatProvider，本文件只做渲染 + 输入。
// 截图纯内存，随会话释放；会话跨进入/返回保留（全局 StateNotifierProvider，页面 dispose
// 不触发 clear），由「新对话」按钮（AppBar）或 App 退出（app.dart didChangeAppLifecycleState
// detached）清空。
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:study_engine/study_engine.dart';

import '../../core/providers/agent_session_provider.dart';
import '../../core/providers/chat_session_provider.dart';
import '../../core/providers/image_pick_provider.dart';
import '../../core/providers/captured_image.dart';
import '../../core/theme/paper_extension.dart';
import '../../core/theme/paper_scaffold.dart';
import '../../core/widgets/ask_user_card.dart';
import '../../core/widgets/markdown_latex.dart';
import 'saved_topic_capsule.dart';

/// 推入全屏 AI 对话页（`/ai`）。
///
/// [screenshot] 可空：来自 [CapturedScreenshot] 的截图（拍题入口 / 分享冷启动），
/// 纯内存持有，会话结束即释放；为 null 时表示纯文字入口。
///
/// 签名保持与历史 `showModalBottomSheet` 版本一致，使各调用方（app.dart 分享冷启动、
/// 今日页 _consumePendingScreenshot、知识点详情页深度交流）零改动。返回的 Future 在
/// 对话页 pop 时完成。
Future<void> showAiPanel(
  BuildContext context, {
  CapturedScreenshot? screenshot,
}) async {
  await context.push('/ai', extra: screenshot);
}

/// 全屏 AI 对话页。由路由 `/ai` 注入可选的 [initialScreenshot]（拍题 / 分享冷启动）。
class AiChatPage extends ConsumerStatefulWidget {
  const AiChatPage({super.key, this.initialScreenshot});

  final CapturedScreenshot? initialScreenshot;

  @override
  ConsumerState<AiChatPage> createState() => _AiChatPageState();
}

class _AiChatPageState extends ConsumerState<AiChatPage> {
  final TextEditingController _inputCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  final FocusNode _inputFocus = FocusNode();
  CapturedScreenshot? _pendingImage; // 待附图（首轮入口或追问轮追加）
  bool _firstSent = false;

  @override
  void initState() {
    super.initState();
    // 首轮：用入口截图作为首条消息的图（拍题 / 分享冷启动预填）。不自动发送。
    _pendingImage = widget.initialScreenshot;
    // 监听会话状态变化：仅在有新消息/流式增量时滚动到底部。
    ref.listenManual(currentChatProvider, (prev, next) {
      if (prev == null) return;
      final grew = next.messages.length != prev.messages.length ||
          next.streamingText.length != prev.streamingText.length;
      if (grew) _scheduleScrollToBottom();
    });
  }

  @override
  void dispose() {
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  void _scheduleScrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
      }
    });
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

  // ---- 输入区语义：按 pendingAsk 切换（agent 挂起提问 vs 正常对话）----

  /// 输入框是否可编辑：busy 禁用；pendingAsk 含选项时须点上方选项（禁用自由输入）；
  /// pendingAsk 自由输入模式可编辑；正常对话可编辑。
  bool _inputEnabled(ChatSessionState state) {
    if (state.busy) return false;
    if (state.pendingAsk != null && !state.pendingAsk!.isFreeInput) return false;
    return true;
  }

  String _inputHint(ChatSessionState state) {
    if (state.pendingAsk != null) {
      return state.pendingAsk!.isFreeInput ? '请输入答案' : '请选择上方选项';
    }
    return _firstSent ? '追问...' : '补充说明（可选）';
  }

  /// 输入行提交回调；返回 null 表示禁用（busy 或 pendingAsk 含选项须点选项卡）。
  VoidCallback? _onInputSubmit(ChatSessionState state) {
    if (state.busy) return null;
    if (state.pendingAsk != null) {
      if (state.pendingAsk!.isFreeInput) {
        return () => _submitFreeAnswer();
      }
      return null; // 含选项：须点 AskUserCard 里的选项
    }
    return _send;
  }

  /// 自由输入模式提交：把输入框文本作为答案回灌挂起的 agent。
  void _submitFreeAnswer() {
    final text = _inputCtrl.text.trim();
    if (text.isEmpty) return;
    _inputCtrl.clear();
    ref.read(currentChatProvider.notifier).respondToAsk(text);
  }

  String _inputButtonLabel(ChatSessionState state) {
    if (state.busy) return '分析中...';
    if (state.pendingAsk != null) {
      return state.pendingAsk!.isFreeInput ? '提交答案' : '请选择上方选项';
    }
    return _firstSent ? '发送' : '开始分析';
  }

  /// 追问轮加图：Sheet 选拍照/相册 → pickImageForAi → setState 更新 _pendingImage。
  ///
  /// 取消拍照/裁剪（返回 null）则不追加图。
  Future<void> _attachCroppedImage({required bool fromCamera}) async {
    final screenshot = await pickImageForAi(fromCamera: fromCamera);
    if (screenshot == null || !mounted) return;
    final cropped = await context.push<CapturedScreenshot>(
      '/crop',
      extra: screenshot.pngBytes,
    );
    if (cropped == null || !mounted) return;
    setState(() => _pendingImage = cropped);
  }

  /// 追问轮加图：Sheet 选拍照/相册 → 复用 _attachCroppedImage。
  Future<void> _pickImageForFollowUp(BuildContext context) async {
    final fromCamera = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('拍照'),
              onTap: () => Navigator.of(sheetCtx).pop(true),
            ),
            ListTile(
              leading: const Icon(Icons.photo_outlined),
              title: const Text('从相册选择'),
              onTap: () => Navigator.of(sheetCtx).pop(false),
            ),
          ],
        ),
      ),
    );
    if (fromCamera == null || !mounted) return; // Sheet 滑掉/点外区
    await _attachCroppedImage(fromCamera: fromCamera);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(currentChatProvider);
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    // 纸感扩展兜底：未装配 PaperColors 的上下文（如 widget 测试裸 MaterialApp）
    // 退回亮色日光纸，避免 null 崩溃。
    final paper = theme.extension<PaperColors>() ?? PaperColors.light;

    // 派生空态：历史为空 + 当前没有待附图（ishistory）→ 显示空态引导。
    final hasHistory = state.messages.isNotEmpty;
    final showEmptyState = !hasHistory && _pendingImage == null;

    return PaperScaffold(
      appBar: AppBar(
        title: const Text('问 AI'),
        actions: [
          IconButton(
            tooltip: '新对话',
            icon: const Icon(Icons.refresh, size: 20),
            // 禁用：空会话清空无意义；运行中清会丢当前流式输出。
            onPressed: state.busy || state.messages.isEmpty
                ? null
                : () {
                    ref.read(currentChatProvider.notifier).clear();
                    _inputCtrl.clear();
                    setState(() {
                      _pendingImage = null;
                      _firstSent = false;
                    });
                    if (_scrollCtrl.hasClients) _scrollCtrl.jumpTo(0);
                  },
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 空态引导：首次进入对话页（无历史 + 无待附图）
            if (showEmptyState)
              _EmptyState(
                paper: paper,
                onCamera: () => _attachCroppedImage(fromCamera: true),
                onGallery: () => _attachCroppedImage(fromCamera: false),
                onInput: () => _inputFocus.requestFocus(),
              ),
            // 消息列表
            Expanded(
              child: ListView(
                controller: _scrollCtrl,
                children: [
                  ...state.messages
                      .map((m) => _buildMessage(m, theme, state.messages)),
                  // 流式文本（当前轮 LLM 正在输出）
                  if (state.streamingText.isNotEmpty)
                    _AiNote(
                      text: state.streamingText,
                      toolEvents: state.toolEvents,
                      colorScheme: colorScheme,
                      theme: theme,
                    ),
                  // ask_user 提问卡片：agent 挂起等用户作答。
                  if (state.pendingAsk != null)
                    AskUserCard(
                      request: state.pendingAsk!,
                      onSubmit: (answer) => ref
                          .read(currentChatProvider.notifier)
                          .respondToAsk(answer),
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
            // 输入行：加图按钮 + TextField + 发送/开始分析按钮。
            const SizedBox(height: 8),
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.add_photo_alternate_outlined),
                  onPressed: state.busy
                      ? null
                      : () => _pickImageForFollowUp(context),
                ),
                Expanded(
                  child: TextField(
                    controller: _inputCtrl,
                    focusNode: _inputFocus,
                    // pendingAsk 含选项时禁用自由输入（须点上方选项）；自由输入
                    // 模式或正常模式可输入。
                    enabled: !state.busy && _inputEnabled(state),
                    decoration: InputDecoration(
                      hintText: _inputHint(state),
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                    onSubmitted: (_) => _onInputSubmit(state),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: _onInputSubmit(state) == null
                      ? null
                      : () => _onInputSubmit(state)!(),
                  icon: Icon(
                    state.busy
                        ? Icons.hourglass_top
                        : (state.pendingAsk != null
                            ? Icons.check
                            : Icons.edit_note),
                    size: 18,
                  ),
                  label: Text(_inputButtonLabel(state)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 按消息角色分派渲染:user → 用户气泡;assistant → AI note;tool → 工具轨迹。
  ///
  /// [allMessages] 为跨轮持久的全量消息列表,用于在 assistant 消息分支
  /// 提取 save_review 卡片所需 review_id(从同轮 tool 消息 content 解析)。
  Widget _buildMessage(
      ChatMessage msg, ThemeData theme, List<ChatMessage> allMessages) {
    if (msg.role == 'user') {
      final text = _extractText(msg);
      final images = _extractImages(msg);
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: _UserBubble(
          query: text.isEmpty ? '（附图分析）' : text,
          images: images,
          colorScheme: theme.colorScheme,
          theme: theme,
        ),
      );
    }
    if (msg.role == 'assistant') {
      final text = _extractText(msg);
      final cards = _reviewCardsFromToolCalls(msg.toolCalls, allMessages);
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _AiNote(
              text: text,
              toolEvents: const [],
              colorScheme: theme.colorScheme,
              theme: theme,
            ),
            ...cards,
          ],
        ),
      );
    }
    if (msg.role == 'tool') {
      final content = _extractText(msg);
      final name = _toolCallName(msg.toolCallId, allMessages);
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: buildToolResultWidget(
          name: name,
          result: content,
          line: '← $content',
          colorScheme: theme.colorScheme,
          theme: theme,
        ),
      );
    }
    return const SizedBox.shrink();
  }

  /// 在 assistant 消息的 toolCalls 中按 toolCallId 反查 tool name（供 tool 消息分支决策渲染）。
  ///
  /// 与 [_reviewCardsFromToolCalls] 同模式:tool 消息本身不带 name,需回溯 assistant
  /// 的 toolCalls 列表。未匹配返回空串（→ 回退普通轨迹行）。
  String _toolCallName(String? toolCallId, List<ChatMessage> allMessages) {
    if (toolCallId == null) return '';
    for (final m in allMessages) {
      final tcs = m.toolCalls;
      if (tcs == null) continue;
      for (final tc in tcs) {
        if (tc.id == toolCallId) return tc.name;
      }
    }
    return '';
  }

  /// 从 assistant 消息的 toolCalls 提取 save_review 调用,渲染对应卡片列表。
  ///
  /// 数据源是已落库的 messages(跨轮持久),不是 state.toolEvents(每轮清空)。
  /// review_id 从对应的 tool 消息(role=='tool' 且 toolCallId 匹配)content 解析。
  List<Widget> _reviewCardsFromToolCalls(
      List<ToolCall>? toolCalls, List<ChatMessage> allMessages) {
    if (toolCalls == null) return const [];
    return toolCalls
        .where((tc) => tc.name == 'save_review')
        .map((tc) {
          // 在同轮 tool 消息里按 toolCallId 查 result(含 review_id=N)。
          // tool 消息由 AgentRoundEndEvent 落库(chat_session_provider.dart),跨轮持久。
          String rawResult = '';
          try {
            final toolMsg = allMessages.firstWhere(
              (m) => m.role == 'tool' && m.toolCallId == tc.id,
            );
            rawResult = _extractText(toolMsg);
          } catch (_) {}
          return _ReviewCard(
            rawArguments: tc.arguments,
            rawResult: rawResult,
            toolCallId: tc.id,
          );
        })
        .toList();
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

  /// 从 ChatMessage.content 抽取所有图片（vision message）→ 同步解码出字节列表。
  ///
  /// 解码失败的图跳过（视为损坏），让 UI 仅渲染能显示的图，避免一坏全坏。
  /// 同一消息可附多图（OpenAI 兼容多 content_part），按出现顺序排列。
  List<Uint8List> _extractImages(ChatMessage msg) {
    final c = msg.content;
    if (c is! List<ContentPart>) return const [];
    final out = <Uint8List>[];
    for (final p in c) {
      if (p is! ImageUrlPart) continue;
      final bytes = _decodeDataUri(p.url);
      if (bytes != null) out.add(bytes);
    }
    return out;
  }

  /// 解码 `data:image/<mime>;base64,<payload>` → Uint8List。
  ///
  /// 不接受非 data: URI（http URL 不在用户消息场景里——本面板截图走 base64 内联），
  /// 不接受 payload 缺失/空/base64 解码失败——均返回 null，由调用方决定是否跳过。
  Uint8List? _decodeDataUri(String uri) {
    const prefix = 'data:';
    if (!uri.startsWith(prefix)) return null;
    final comma = uri.indexOf(',');
    if (comma < 0 || comma == uri.length - 1) return null;
    final meta = uri.substring(prefix.length, comma);
    if (!meta.contains(';base64')) return null;
    final payload = uri.substring(comma + 1);
    try {
      return base64Decode(payload);
    } catch (_) {
      return null;
    }
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
/// 朱砂左边框 3px + 斜体 bodyMedium）+ 可选内联图片（多图横排，最大高 180px）。
///
/// [images] 为消息携带的图片字节列表（来自 vision content parts），
/// 与文字一起作为对话内容内联展示，不再被忽略。
class _UserBubble extends StatelessWidget {
  const _UserBubble({
    required this.query,
    required this.colorScheme,
    required this.theme,
    this.images = const [],
  });

  final String query;
  final List<Uint8List> images;
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  query,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontStyle: FontStyle.italic,
                  ),
                ),
                if (images.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  _AttachedImageGrid(images: images, theme: theme),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 内联图片网格：多图横排（最多 3 列），单图最大高 180、宽按比例，
/// 圆角 8、暖色细边，与气泡文字协调而不喧宾夺主。
class _AttachedImageGrid extends StatelessWidget {
  const _AttachedImageGrid({required this.images, required this.theme});
  final List<Uint8List> images;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final colorScheme = theme.colorScheme;
    final tiles = <Widget>[];
    for (final bytes in images) {
      tiles.add(ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(color: colorScheme.outlineVariant, width: 0.5),
          ),
          child: Image.memory(
            bytes,
            height: 180,
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) => Container(
              height: 60,
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                '图片已损坏',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
      ));
    }
    // 用 Wrap 实现横排+换行（多图时自动堆叠）。间距 6。
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: tiles,
    );
  }
}

// ─────────────────────────────────────────────────────────────
// 私有 widget：AI 回复（ai-note）
// ─────────────────────────────────────────────────────────────

/// AI 回复容器：surfaceContainerLow 底 + Markdown/LaTeX 渲染。
///
/// [toolEvents] 为当前轮流式工具轨迹（仅流式气泡传入；历史 assistant 消息传空）。
class _AiNote extends StatelessWidget {
  const _AiNote({
    required this.text,
    required this.toolEvents,
    required this.colorScheme,
    required this.theme,
  });

  final String text;
  final List<ToolEvent> toolEvents;
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
          ...toolEvents.map((e) => buildToolResultWidget(
                name: e.name,
                result: e.result,
                line: '${e.name}: ${e.result}',
                colorScheme: colorScheme,
                theme: theme,
              )),
          if (text.isNotEmpty) ...[
            if (toolEvents.isNotEmpty) const SizedBox(height: 6),
            MarkdownLatex(data: text, selectable: true),
          ],
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// 私有函数：工具结果渲染（save_topic 卡片 / 普通轨迹行）
// ─────────────────────────────────────────────────────────────

/// 工具结果渲染：当工具为 `save_topic` 且 [result] 是合法 `{id, is_new, msg}` JSON 时，
/// 渲染可点击的 [SavedTopicCapsule]；否则（非 save_topic 或 JSON 解析失败）回退普通
/// [ToolTraceLine]（[line] 为展示文案），保证解析失败不崩。
Widget buildToolResultWidget({
  required String name,
  required String result,
  required String line,
  required ColorScheme colorScheme,
  required ThemeData theme,
}) {
  if (name == 'save_topic') {
    try {
      final decoded = jsonDecode(result);
      if (decoded is Map && decoded['id'] is int) {
        return SavedTopicCapsule(
          id: decoded['id'] as int,
          isNew: decoded['is_new'] as bool? ?? false,
        );
      }
    } catch (_) {
      // 非合法 JSON，回退普通工具轨迹行
    }
  }
  return _ToolTraceLine(line: line, colorScheme: colorScheme, theme: theme);
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

// ─────────────────────────────────────────────────────────────
// 私有 widget：空态引导（首次进入对话页）
// ─────────────────────────────────────────────────────────────

/// 空态引导：消息列表为空且无待附图时显示。
/// 三个入口均为对话页内可发起的入口：拍照 / 从相册选择 / 直接输入文字。
/// 用户从今日页进入对话页后，可在此选择「先拍照问一道题」或「直接打字」。
///
/// 视觉：朱砂✦ 大字 + 提示句 + 三行 FilledButton.tonal（与今日页保持一致）。
class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.paper,
    required this.onCamera,
    required this.onGallery,
    required this.onInput,
  });

  final PaperColors paper;
  final VoidCallback onCamera;
  final VoidCallback onGallery;
  final VoidCallback onInput;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Center(
            child: Text(
              '✦',
              style: TextStyle(
                fontSize: 36,
                color: cs.primary,
                height: 1.0,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '问 AI',
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontFamily: 'NotoSerifSC',
              fontWeight: FontWeight.w700,
              color: cs.onSurface,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '拍照问一道题，或直接输入你的疑问',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: cs.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 24),
          FilledButton.tonalIcon(
            onPressed: onCamera,
            icon: const Icon(Icons.photo_camera_outlined),
            label: const Text(
              '拍照',
              style: TextStyle(fontFamily: 'NotoSerifSC', fontSize: 14),
            ),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
            ),
          ),
          const SizedBox(height: 10),
          FilledButton.tonalIcon(
            onPressed: onGallery,
            icon: const Icon(Icons.photo_library_outlined),
            label: const Text(
              '从相册选择',
              style: TextStyle(fontFamily: 'NotoSerifSC', fontSize: 14),
            ),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
            ),
          ),
          const SizedBox(height: 10),
          FilledButton.tonalIcon(
            onPressed: onInput,
            icon: const Icon(Icons.edit_note),
            label: const Text(
              '直接输入文字',
              style: TextStyle(fontFamily: 'NotoSerifSC', fontSize: 14),
            ),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// 私有 widget：批改卡片（save_review）
// ─────────────────────────────────────────────────────────────

/// 批改卡片：save_review 落库后渲染，点进看逐题明细（Task 7 的 ReviewDetailPage）。
///
/// 摘要与题数从 [rawArguments]（ToolCall.arguments 原始 JSON）解析；
/// review_id 从 [rawResult]（同轮 tool 消息 content，含 review_id=N）解析。
/// 全部 paper 字段走可空 + colorScheme 兜底（测试用裸 MaterialApp 无 PaperColors 扩展）。
class _ReviewCard extends StatelessWidget {
  final String rawArguments; // ToolCall.arguments，原始 JSON
  final String rawResult; // tool 消息 content，含 review_id=N（可空串）
  final String toolCallId; // ToolCall.id，用于唯一 key（同消息多卡片不冲突）
  const _ReviewCard({
    required this.rawArguments,
    required this.rawResult,
    required this.toolCallId,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final paper = theme.extension<PaperColors>();
    final cs = theme.colorScheme;
    // 从 arguments 解析摘要；解析失败兜底"批改报告"
    String summary = '批改报告';
    try {
      final obj = jsonDecode(rawArguments) as Map<String, dynamic>;
      if (obj['summary'] is String) summary = obj['summary'] as String;
    } catch (_) {}
    final match = RegExp(r'review_id=(\d+)').firstMatch(rawResult);
    final reviewId = match == null ? null : int.parse(match.group(1)!);
    return Card(
      key: ValueKey('review_card_$toolCallId'),
      color: paper?.polaroidBg ?? cs.surfaceContainerLow,
      elevation: 2,
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: ListTile(
        leading: Icon(Icons.rate_review, color: paper?.stampRed ?? cs.primary),
        title: Text('批改报告', style: theme.textTheme.titleSmall),
        subtitle: Text(summary, maxLines: 2, overflow: TextOverflow.ellipsis),
        trailing: reviewId == null
            ? null
            : IconButton(
                icon: const Icon(Icons.chevron_right),
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => ReviewDetailPage(reviewId: reviewId),
                )),
              ),
      ),
    );
  }
}

/// 批改详情页:逐题明细 + 底部复盘输入(走同一 chat session)。
class ReviewDetailPage extends ConsumerWidget {
  final int reviewId;
  const ReviewDetailPage({super.key, required this.reviewId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reviewAsync = ref.watch(reviewRepositoryProvider);
    final inputCtrl = TextEditingController();
    return Scaffold(
      appBar: AppBar(title: const Text('批改详情')),
      body: reviewAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('加载失败: $e')),
        data: (repo) => FutureBuilder<Review?>(
          future: repo.findById(reviewId),
          builder: (_, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            final review = snap.data;
            if (review == null) return const Center(child: Text('批改记录不存在'));
            return Column(
              children: [
                Expanded(child: ListView(
                  padding: const EdgeInsets.all(12),
                  children: [
                    Text(review.summary, style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    ...review.items.map((it) => _ReviewItemTile(item: it)),
                  ],
                )),
                _ReviewReplyBar(controller: inputCtrl, onSubmit: (text) {
                  ref.read(currentChatProvider.notifier).send(text);
                  inputCtrl.clear();
                  Navigator.of(context).pop(); // 回到对话流看回复
                }),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// 逐题明细行:徽标 + 题目 + 你的答案 + 解析 + 涉及知识点。
class _ReviewItemTile extends StatelessWidget {
  const _ReviewItemTile({required this.item});
  final ReviewItem item;

  /// 徽标:correct→墨绿✓、partial→朱砂◐、wrong→朱砂✗。
  ({String label, Color color}) _badge() {
    switch (item.verdict) {
      case 'correct':
        return (label: '✓', color: const Color(0xFF2E7D32));
      case 'partial':
        return (label: '◐', color: const Color(0xFFC62828));
      default:
        return (label: '✗', color: const Color(0xFFC62828));
    }
  }

  @override
  Widget build(BuildContext context) {
    final paper = Theme.of(context).extension<PaperColors>();
    final cs = Theme.of(context).colorScheme;
    final badge = _badge();
    final topicText = item.topicIds.isEmpty
        ? null
        : '涉及知识点: ${item.topicIds.join(', ')}';
    return Card(
      color: paper?.polaroidBg ?? cs.surfaceContainerLow,
      elevation: 1,
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 26,
                  height: 26,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: badge.color,
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    badge.label,
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${item.seq}. ${item.question}',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
            if (item.userAnswer != null) ...[
              const SizedBox(height: 8),
              Text('你的答案: ${item.userAnswer}', style: Theme.of(context).textTheme.bodySmall),
            ],
            const SizedBox(height: 4),
            Text('解析: ${item.analysis}', style: Theme.of(context).textTheme.bodySmall),
            if (topicText != null) ...[
              const SizedBox(height: 4),
              Text(topicText, style: Theme.of(context).textTheme.bodySmall),
            ],
          ],
        ),
      ),
    );
  }
}

/// 底部复盘输入条:输入问题 → onSubmit 回调解发(走同一 chat session)。
class _ReviewReplyBar extends StatelessWidget {
  const _ReviewReplyBar({required this.controller, required this.onSubmit});
  final TextEditingController controller;
  final ValueChanged<String> onSubmit;

  @override
  Widget build(BuildContext context) {
    final paper = Theme.of(context).extension<PaperColors>();
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        decoration: BoxDecoration(
          color: paper?.polaroidBg ?? cs.surface,
          border: Border(top: BorderSide(color: paper?.ruleSoft ?? cs.outlineVariant)),
        ),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                textInputAction: TextInputAction.done,
                decoration: const InputDecoration(
                  hintText: '输入复盘问题,继续追问…',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (text) {
                  final trimmed = text.trim();
                  if (trimmed.isEmpty) return;
                  onSubmit(trimmed);
                },
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              icon: Icon(Icons.send, color: paper?.stampRed ?? cs.primary),
              tooltip: '发送',
              onPressed: () {
                final text = controller.text.trim();
                if (text.isEmpty) return;
                onSubmit(text);
              },
            ),
          ],
        ),
      ),
    );
  }
}
