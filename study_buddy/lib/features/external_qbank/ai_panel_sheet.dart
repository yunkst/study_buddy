// 纸感学术 AI 对话页（全屏）：消息列表多轮对话（拍立得截图 + 用户气泡 + 工具轨迹 + AI 回复）。
//
// 由路由 `/ai` 承载（顶层 GoRoute，root navigator 承载 → 全屏盖住底部导航）。
// 进入方式：今日页「问 AI」入口 / 知识点详情页「问 AI 深度交流」/ 分享冷启动带图。
//
// 多轮架构（spec §3）：状态在 currentChatProvider，本文件只做渲染 + 输入。
// 截图纯内存，随会话释放；会话跨进入/返回保留（全局 StateNotifierProvider，页面 dispose
// 不触发 clear），由「新对话」按钮（AppBar）或 App 退出（app.dart didChangeAppLifecycleState
// detached）清空。
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:go_router/go_router.dart';
import 'package:study_engine/study_engine.dart';

import '../../core/providers/agent_session_provider.dart';
import '../../core/providers/chat_session_provider.dart';
import '../../core/providers/database_provider.dart';
import '../../core/providers/dev_mode_provider.dart';
import '../../core/providers/image_pick_provider.dart';
import '../../core/providers/captured_image.dart';
import '../../core/services/logger_service.dart';
import '../../core/theme/paper_extension.dart';
import '../../core/theme/paper_scaffold.dart';
import '../../core/widgets/ask_user_card.dart';
import '../../core/widgets/ask_user_input_semantics.dart';
import '../../core/widgets/markdown_latex.dart';
import 'saved_topic_capsule.dart';

/// 对话页启动参数：截图（拍题/分享冷启动）与知识点教学入口（【为什么？】）可并存。
class AiPanelLaunch {
  const AiPanelLaunch({this.screenshot, this.topicId});

  /// 拍题/分享冷启动预填的截图；null = 纯文字入口。
  final CapturedScreenshot? screenshot;

  /// 知识点教学入口的 topic id（详情页【为什么？】）；null = 普通会话。
  final int? topicId;
}

/// 推入全屏 AI 对话页（`/ai`）。
///
/// [screenshot] 可空：来自 [CapturedScreenshot] 的截图（拍题入口 / 分享冷启动），
/// 纯内存持有，会话结束即释放；为 null 时表示纯文字入口。
///
/// [topicId] 可空：知识点详情页【为什么？】入口传入，进入后启动「知识点教学模式」
/// （AI 从场景出发做启发式教学）。为 null 时是普通学习伴侣会话。
///
/// 签名保持与历史 `showModalBottomSheet` 版本一致，使各调用方（app.dart 分享冷启动、
/// 今日页 _consumePendingScreenshot、知识点详情页深度交流）零改动。返回的 Future 在
/// 对话页 pop 时完成。
Future<void> showAiPanel(
  BuildContext context, {
  CapturedScreenshot? screenshot,
  int? topicId,
}) async {
  await context.push(
    '/ai',
    extra: AiPanelLaunch(screenshot: screenshot, topicId: topicId),
  );
}

/// 全屏 AI 对话页。由路由 `/ai` 注入可选的 [initialScreenshot]（拍题 / 分享冷启动）
/// 与 [initialTopicId]（知识点详情页【为什么？】教学入口）。
class AiChatPage extends ConsumerStatefulWidget {
  const AiChatPage({super.key, this.initialScreenshot, this.initialTopicId});

  final CapturedScreenshot? initialScreenshot;
  final int? initialTopicId;

  @override
  ConsumerState<AiChatPage> createState() => _AiChatPageState();
}

class _AiChatPageState extends ConsumerState<AiChatPage> {
  final TextEditingController _inputCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  final FocusNode _inputFocus = FocusNode();
  CapturedScreenshot? _pendingImage; // 待附图（首轮入口或追问轮追加）
  bool _firstSent = false;
  /// 是否教学开场（详情页【为什么？】入口）：开场指令 user 消息渲染为居中引导横幅
  /// 而非用户气泡；用户自行发送首条消息后（_firstSent=true）恢复普通气泡。
  bool _teachingOpening = false;

  /// 会话状态来源：教学入口（initialTopicId != null）→ topicTeachingProvider，
  /// 否则主线（currentChatProvider）。教学与主线完全隔离，互不覆盖。
  /// late final：initState 中按入口赋值，build（ref.watch）在 initState 之后才执行。
  late final StateNotifierProvider<ChatSessionNotifier, ChatSessionState>
      _chatProvider;

  bool get _isTeaching => widget.initialTopicId != null;

  @override
  void initState() {
    super.initState();
    // 按入口选择会话 provider：教学走独立 provider，主线走 currentChatProvider。
    _chatProvider = _isTeaching ? topicTeachingProvider : currentChatProvider;
    // 冷启动恢复最近会话（续聊）：仅主线；教学路径由 startTeaching 自行恢复历史。
    if (!_isTeaching) {
      ref.read(_chatProvider.notifier).hydrate();
    }
    // 首轮：用入口截图作为首条消息的图（拍题 / 分享冷启动预填）。不自动发送。
    _pendingImage = widget.initialScreenshot;
    _teachingOpening = _isTeaching;
    // 教学兜底启动：从详情页进入时 startTeaching 已完成/进行中则跳过；
    // 深链/分享直达空态时补发开场。延迟到首帧后执行（send 修改 provider，
    // initState 期间违反 Riverpod 3 构建期约束）。
    if (_isTeaching) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final s = ref.read(topicTeachingProvider);
        if (!s.busy && s.messages.isEmpty) {
          unawaited(ref
              .read(topicTeachingProvider.notifier)
              .startTeaching(widget.initialTopicId!));
        }
      });
    }
    // 输入文本变化时重算发送按钮可用态（canSend 依赖 _inputCtrl.text）。
    _inputCtrl.addListener(_onInputChanged);
    // 监听会话状态变化：仅在有新消息/流式增量时滚动到底部。
    ref.listenManual(_chatProvider, (prev, next) {
      if (prev == null) return;
      final grew = next.messages.length != prev.messages.length ||
          next.streamingText.length != prev.streamingText.length;
      if (grew) _scheduleScrollToBottom();
    });
  }

  /// 文本变化触发 rebuild：微信风发送按钮随输入内容实时切换可用态。
  void _onInputChanged() => setState(() {});

  @override
  void dispose() {
    _inputCtrl.removeListener(_onInputChanged);
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
    await ref.read(_chatProvider.notifier).send(text, image: image);
  }

  // 输入区语义判定委托给共享的 AskUserInputSemantics（与 plan_chat_sheet 共用），
// 避免分支逻辑双写。onSubmit 行为在本类内联（_submitFreeAnswer / _send）。

  /// 自由输入模式提交：把输入框文本作为答案回灌挂起的 agent。
  void _submitFreeAnswer() {
    final text = _inputCtrl.text.trim();
    if (text.isEmpty) return;
    _inputCtrl.clear();
    ref.read(_chatProvider.notifier).respondToAsk(text);
  }

  /// 构造当前输入区语义。sheet 状态 _firstSent + state.busy + state.pendingAsk。
  AskUserInputSemantics _semantics(ChatSessionState state) => AskUserInputSemantics(
        busy: state.busy,
        pendingAsk: state.pendingAsk,
        firstSent: _firstSent,
      );

  /// 输入行提交回调；返回 null 表示禁用（busy 或 pendingAsk 含选项须点选项卡）。
  VoidCallback? _onInputSubmit(ChatSessionState state) {
    if (state.busy) return null;
    if (state.pendingAsk != null) {
      if (state.pendingAsk!.isFreeInput) {
        return _submitFreeAnswer;
      }
      return null; // 含选项：须点 AskUserCard 里的选项
    }
    return _send;
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
    final state = ref.watch(_chatProvider);
    final devMode = ref.watch(devModeProvider).value ?? false;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    // 纸感扩展兜底：未装配 PaperColors 的上下文（如 widget 测试裸 MaterialApp）
    // 退回亮色日光纸，避免 null 崩溃。
    final paper = theme.extension<PaperColors>() ?? PaperColors.light;

    // 派生空态：历史为空 + 当前没有待附图（ishistory）→ 显示空态引导。
    final hasHistory = state.messages.isNotEmpty;
    final showEmptyState = !hasHistory && _pendingImage == null;

    // 微信风发送可用态：有正文或待附图才可发送。
    final canSend = _inputCtrl.text.trim().isNotEmpty || _pendingImage != null;

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
                    ref.read(_chatProvider.notifier).clear();
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
            // 教学入口：顶部常驻可折叠知识卡（标题 + 引子/答案缩略，点回详情页）。
            if (_isTeaching) _TopicHeaderCard(topicId: widget.initialTopicId!),
            // 空态引导：首次进入对话页（无历史 + 无待附图）
            // 用 Expanded + ListView 占据消息区，展示插画占位而非 3 个按钮。
            // 开发者模式面板在空态下也可见（调试工具，应始终可访问）。
            if (showEmptyState)
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) => ListView(
                    children: [
                      if (devMode)
                        Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 4),
                          child: _InjectedContextPanel(
                            teachingTopicId: state.teachingTopicId,
                          ),
                        ),
                      SizedBox(
                        height: constraints.maxHeight -
                            (devMode ? 60 : 0), // 减去开发者模式面板大致高度
                        child: const _EmptyState(),
                      ),
                    ],
                  ),
                ),
              ),
            // 消息列表
            if (!showEmptyState)
              Expanded(
                child: ListView(
                  controller: _scrollCtrl,
                  children: [
                    // 开发者模式：顶部展示本轮隐式注入的上下文（system prompt 动态字段
                    // + 随用户消息注入的经验记忆），调试 LLM 实际收到什么。
                    if (devMode)
                      _InjectedContextPanel(
                        teachingTopicId: state.teachingTopicId,
                      ),
                    ...state.messages
                        .map((m) => _buildMessage(m, theme, state.messages, devMode)),
                    // 「AI 正在思考…」指示器：busy 且暂无流式文本/挂起提问时显示。
                    // 覆盖此前无反馈的几个时刻——发送后首 token 延迟、工具执行间隙、
                    // 多轮 ReAct 轮次切换空窗——消除「AI 卡住」的错觉。
                    if (state.busy &&
                        state.streamingText.isEmpty &&
                        state.pendingAsk == null)
                      _ThinkingIndicator(
                        toolEvents: state.toolEvents,
                        devMode: devMode,
                        colorScheme: colorScheme,
                        theme: theme,
                      ),
                    // 流式文本（当前轮 LLM 正在输出）
                    if (state.streamingText.isNotEmpty)
                      _AiNote(
                        text: state.streamingText,
                        toolEvents: state.toolEvents,
                        devMode: devMode,
                        colorScheme: colorScheme,
                        theme: theme,
                      ),
                    // ask_user 提问卡片：agent 挂起等用户作答。
                    if (state.pendingAsk != null)
                      AskUserCard(
                        request: state.pendingAsk!,
                        onSubmit: (answer) => ref
                            .read(_chatProvider.notifier)
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
            // 输入行：微信风——➕ 加图在前，圆角输入框后是小号发送按钮。
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                IconButton(
                  icon: const Icon(Icons.add_photo_alternate_outlined),
                  onPressed: state.busy
                      ? null
                      : () => _pickImageForFollowUp(context),
                  tooltip: '拍照或从相册选择',
                ),
                Builder(builder: (ctx) {
                  final s = _semantics(state);
                  return Expanded(
                    child: TextField(
                      controller: _inputCtrl,
                      focusNode: _inputFocus,
                      enabled: s.inputEnabled,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _onInputSubmit(state)?.call(),
                      decoration: InputDecoration(
                        hintText: s.hint,
                        isDense: true,
                        filled: true,
                        fillColor: colorScheme.surfaceContainerHighest
                            .withValues(alpha: 0.4),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 10),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(20),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  );
                }),
                _SendButton(
                  canSend: canSend,
                  semantics: _semantics(state),
                  onTap: _onInputSubmit(state),
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
  /// [devMode] 为开发者模式：tool 消息渲染可展开详情卡片（含参数/结果 JSON）。
  Widget _buildMessage(ChatMessage msg, ThemeData theme,
      List<ChatMessage> allMessages, bool devMode) {
    if (msg.role == 'user') {
      // 教学开场：系统代发的首条 user 消息（用户未接管前）渲染为居中引导横幅，
      // 而非用户气泡；用户自行发送消息后恢复普通气泡。
      final isTeachingOpening = _teachingOpening &&
          !_firstSent &&
          allMessages.isNotEmpty &&
          identical(allMessages.first, msg);
      if (isTeachingOpening) {
        return const _TeachingOpeningBanner();
      }
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
              devMode: devMode,
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
      final call = _toolCallById(msg.toolCallId, allMessages);
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: buildToolResultWidget(
          name: call?.name ?? '',
          result: content,
          line: '← $content',
          arguments: call?.arguments,
          devMode: devMode,
          colorScheme: theme.colorScheme,
          theme: theme,
        ),
      );
    }
    return const SizedBox.shrink();
  }

  /// 在 assistant 消息的 toolCalls 中按 toolCallId 反查 ToolCall（工具名 + 参数）。
  ///
  /// 与 [_reviewCardsFromToolCalls] 同模式:tool 消息本身不带 name/arguments,
  /// 需回溯 assistant 的 toolCalls 列表。未匹配返回 null（→ 回退普通轨迹行）。
  ToolCall? _toolCallById(String? toolCallId, List<ChatMessage> allMessages) {
    if (toolCallId == null) return null;
    for (final m in allMessages) {
      final tcs = m.toolCalls;
      if (tcs == null) continue;
      for (final tc in tcs) {
        if (tc.id == toolCallId) return tc;
      }
    }
    return null;
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
// 私有 widget：教学开场引导横幅
// ─────────────────────────────────────────────────────────────

/// 教学开场引导横幅：知识点详情页【为什么？】入口自动开场时，代替用户气泡
/// 显示居中的「✦ 从场景出发，认识这个知识点」提示，表明 AI 正在开场教学。
class _TeachingOpeningBanner extends StatelessWidget {
  const _TeachingOpeningBanner();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: cs.outlineVariant, width: 0.5),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('✦', style: TextStyle(color: cs.primary, fontSize: 14)),
              const SizedBox(width: 6),
              Text(
                '从场景出发，认识这个知识点',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
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
/// [devMode] 开启时工具轨迹渲染为可展开详情卡片（流式期参数尚未产生，仅结果可见）。
class _AiNote extends StatelessWidget {
  const _AiNote({
    required this.text,
    required this.toolEvents,
    required this.devMode,
    required this.colorScheme,
    required this.theme,
  });

  final String text;
  final List<ToolEvent> toolEvents;
  final bool devMode;
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
                devMode: devMode,
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
// 私有 widget：「AI 正在思考…」指示器
// ─────────────────────────────────────────────────────────────

/// 「AI 正在思考…」指示器：三点错峰跳动 + 文案。
///
/// 在 busy 且暂无流式文本/挂起提问时显示于消息列表底部，覆盖「发送后首 token
/// 延迟 / 工具执行间隙 / 多轮 ReAct 切换空窗」这几个此前无反馈、易被误认为
/// 「卡住」的时刻。容器风格沿用 [_AiNote]（全宽 surfaceContainerLow 底），
/// 使「思考中 → 流式输出」的过渡平滑（流式文本到达后本组件被替换为 _AiNote）。
///
/// [toolEvents] 在此期间（streamingText 为空，原 _AiNote 不渲染）一并展示，
/// 让工具执行阶段的轨迹也可见，而非只在有流式文本时才浮现。
/// [devMode] 开启时工具轨迹渲染为可展开详情卡片。
class _ThinkingIndicator extends StatefulWidget {
  const _ThinkingIndicator({
    required this.toolEvents,
    required this.devMode,
    required this.colorScheme,
    required this.theme,
  });

  final List<ToolEvent> toolEvents;
  final bool devMode;
  final ColorScheme colorScheme;
  final ThemeData theme;

  @override
  State<_ThinkingIndicator> createState() => _ThinkingIndicatorState();
}

class _ThinkingIndicatorState extends State<_ThinkingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = widget.colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: cs.surfaceContainerLow),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ...widget.toolEvents.map((e) => buildToolResultWidget(
                name: e.name,
                result: e.result,
                line: '${e.name}: ${e.result}',
                devMode: widget.devMode,
                colorScheme: cs,
                theme: widget.theme,
              )),
          if (widget.toolEvents.isNotEmpty) const SizedBox(height: 6),
          Row(
            children: [
              _TypingDots(controller: _ctrl, color: cs.primary),
              const SizedBox(width: 8),
              Text(
                'AI 正在思考…',
                style: widget.theme.textTheme.bodyMedium?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 三点错峰透明度动画：典型「正在输入」指示。
///
/// 每个点在 1.2s 周期内依次「淡入→全亮→淡出」，错相 0.2，朱砂色。
/// 不跳动、不位移，仅亮度呼吸——比缩放/弹跳更克制，避免长等待时分散注意力。
class _TypingDots extends StatelessWidget {
  const _TypingDots({required this.controller, required this.color});

  final AnimationController controller;
  final Color color;

  Widget _dot(double beginPhase) {
    // beginPhase ∈ [0,1)：该点的亮起起点；动画覆盖其后的 0.6 区间。
    final opacity = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween(begin: 0.3, end: 1.0)
            .chain(CurveTween(curve: Curves.easeInOut)),
        weight: 25,
      ),
      TweenSequenceItem(tween: ConstantTween(1.0), weight: 8),
      TweenSequenceItem(
        tween: Tween(begin: 1.0, end: 0.3)
            .chain(CurveTween(curve: Curves.easeInOut)),
        weight: 25,
      ),
      TweenSequenceItem(tween: ConstantTween(0.3), weight: 42),
    ]).animate(
      CurvedAnimation(
        parent: controller,
        curve: Interval(
          beginPhase,
          (beginPhase + 0.6).clamp(0.0, 1.0),
        ),
      ),
    );
    return AnimatedBuilder(
      animation: opacity,
      builder: (_, __) => Opacity(
        opacity: opacity.value,
        child: Container(
          width: 7,
          height: 7,
          margin: const EdgeInsets.symmetric(horizontal: 1.5),
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [_dot(0.0), _dot(0.2), _dot(0.4)],
    );
  }
}

// ─────────────────────────────────────────────────────────────
// 私有 widget：微信风发送按钮
// ─────────────────────────────────────────────────────────────

/// 微信风小号发送按钮：圆角实底（36px），纯图标无文字。
///
/// 状态由 [AskUserInputSemantics] 三态机（busy/pendingAsk）决定图标，
/// [canSend]（有正文或待附图）决定可用态：
/// - busy → 沙漏（灰显禁用）
/// - 有内容可发 → 箭头，primary 底高亮，可点
/// - 空输入 → 箭头灰显禁用；pendingAsk 含选项时也禁用（须点 AskUserCard）
///
/// [onTap] 由调用方传入 `_onInputSubmit(state)`（busy / pendingAsk 含选项时
/// 已为 null → 天然禁用），这里仅叠加 canSend 判空。
class _SendButton extends StatelessWidget {
  const _SendButton({
    required this.canSend,
    required this.semantics,
    required this.onTap,
  });

  final bool canSend;
  final AskUserInputSemantics semantics;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final busy = semantics.busy;
    final enabled = onTap != null && canSend;

    final IconData icon;
    if (busy) {
      icon = Icons.hourglass_top;
    } else if (semantics.buttonIconKey == 'check') {
      icon = Icons.check;
    } else {
      icon = Icons.arrow_upward;
    }

    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: Tooltip(
        message: '发送',
        child: Material(
          color: enabled ? cs.primary : cs.onSurface.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(18),
          child: InkWell(
            onTap: enabled ? onTap : null,
            borderRadius: BorderRadius.circular(18),
            child: SizedBox(
              width: 36,
              height: 36,
              child: Icon(
                icon,
                size: 20,
                color: enabled ? cs.onPrimary : cs.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// 私有函数：工具结果渲染（save_topic 卡片 / 普通轨迹行）
// ─────────────────────────────────────────────────────────────

/// 工具专属渲染器签名：输入 LLM 工具结果 + 当前主题，输出专属 widget（null
/// 表示「结果解析失败/无需专属卡片」，由 [buildToolResultWidget] 回退）。
typedef ToolResultRenderer = Widget? Function(
  String result,
  ColorScheme colorScheme,
  ThemeData theme,
);

/// 工具专属渲染器注册表：name → builder。
///
/// 新增工具专属卡片：在此 map 加一项 `'<tool_name>': _build<YourWidget>`，并写
/// 一个同签名的私有 builder 即可。无需改动 [buildToolResultWidget] 主流程。
final Map<String, ToolResultRenderer> _toolRenderers = {
  'save_topic': _buildSavedTopicCapsule,
  // 未来可加：create_plan / set_mastery / …
};

Widget? _buildSavedTopicCapsule(String result, ColorScheme cs, ThemeData theme) {
  try {
    final decoded = jsonDecode(result);
    if (decoded is Map && decoded['id'] is int) {
      return SavedTopicCapsule(
        id: decoded['id'] as int,
        isNew: decoded['is_new'] as bool? ?? false,
      );
    }
  } catch (e) {
    // 非合法 JSON，回退普通工具轨迹行。工具返回非预期格式说明协议异常，记录排查。
    LoggerService.instance.w('save_topic 结果解析失败,回退普通轨迹行: $e',
        category: LogCategory.ai, tags: const ['save-topic-result']);
  }
  return null;
}

/// 工具结果渲染：先查 [_toolRenderers] 注册表，命中且 builder 返回 non-null 则
/// 用专属卡片（当前仅 `save_topic` → [SavedTopicCapsule]）；否则回退——
/// [devMode] 开启渲染 [_ToolCallDetailCard]（含参数/结果 pretty JSON），
/// 关闭则渲染 [_ToolTraceLine]（[line] 为展示文案）。
///
/// [arguments] 来自 assistant 消息的 ToolCall；流式轨迹阶段尚无参数（null）。
Widget buildToolResultWidget({
  required String name,
  required String result,
  required String line,
  required ColorScheme colorScheme,
  required ThemeData theme,
  String? arguments,
  bool devMode = false,
}) {
  final renderer = _toolRenderers[name];
  if (renderer != null) {
    final w = renderer(result, colorScheme, theme);
    if (w != null) return w;
  }
  if (devMode) {
    return _ToolCallDetailCard(
      name: name,
      arguments: arguments,
      result: result,
      colorScheme: colorScheme,
      theme: theme,
    );
  }
  return _ToolTraceLine(line: line, colorScheme: colorScheme, theme: theme);
}

// ─────────────────────────────────────────────────────────────
// 私有 widget：工具调用详情卡片（开发者模式）
// ─────────────────────────────────────────────────────────────

/// 工具调用详情卡片：开发者模式下替代普通轨迹行的可展开卡片。
///
/// 头行显示工具名 + 状态，点按展开「参数（arguments）」与「结果（result）」
/// 两段，均为 pretty JSON（非 JSON 原样展示）。流式轨迹阶段 [arguments] 为
/// null（本轮结束、assistant 消息落库后才回填参数）。
class _ToolCallDetailCard extends StatefulWidget {
  const _ToolCallDetailCard({
    required this.name,
    required this.arguments,
    required this.result,
    required this.colorScheme,
    required this.theme,
  });

  final String name;
  final String? arguments; // ToolCall.arguments 原始 JSON；null=流式轨迹（尚无参数）
  final String result; // 工具返回文本（JSON 或纯文本）
  final ColorScheme colorScheme;
  final ThemeData theme;

  @override
  State<_ToolCallDetailCard> createState() => _ToolCallDetailCardState();
}

class _ToolCallDetailCardState extends State<_ToolCallDetailCard> {
  bool _expanded = false;

  /// 尝试 pretty JSON；解析失败原样返回（覆盖纯文本工具返回）。
  String _pretty(String raw) {
    try {
      return const JsonEncoder.withIndent('  ').convert(jsonDecode(raw));
    } catch (_) {
      return raw;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    final cs = widget.colorScheme;
    final running = widget.result == '进行中...';
    final label = widget.name.isEmpty ? '（工具）' : widget.name;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 2),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        border: Border.all(color: cs.outlineVariant, width: 0.5),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(
                children: [
                  Icon(Icons.code, size: 14, color: cs.primary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      label,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(
                    running ? '进行中…' : '✓',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: running ? cs.onSurfaceVariant : cs.tertiary,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                    color: cs.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded) ...[
            Divider(height: 1, thickness: 0.5, color: cs.outlineVariant),
            Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _DevField(
                    label: '参数（arguments）',
                    text: widget.arguments == null
                        ? '（流式轨迹，参数待本轮结束后可见）'
                        : _pretty(widget.arguments!),
                    theme: theme,
                  ),
                  const SizedBox(height: 8),
                  _DevField(
                    label: '结果（result）',
                    text: _pretty(widget.result),
                    theme: theme,
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 开发者模式代码块：surfaceContainerHighest 底 + 等宽小字 + 可选中复制。
class _DevCodeBlock extends StatelessWidget {
  const _DevCodeBlock({required this.text, required this.theme});
  final String text;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final cs = theme.colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(4),
      ),
      child: SelectableText(
        text,
        style: theme.textTheme.bodySmall?.copyWith(
          fontFamily: 'monospace',
          fontSize: 11,
          height: 1.4,
        ),
      ),
    );
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
// 私有 widget：已注入上下文面板（开发者模式）
// ─────────────────────────────────────────────────────────────

/// 已注入上下文面板：开发者模式下展示 LLM 每轮实际收到的「隐式注入」内容，
/// 与用户可见的 messages 区分开。三部分：
///   1. 今日日期（{{today}}，system prompt 动态字段）
///   2. 经验记忆（`<memory-context>`，随用户消息注入，hermes 风格）
///   3. 知识点教学上下文（{{topic_context}}，详情页【为什么？】入口时注入）
///
/// 默认折叠为一行，点按展开。数据从 `agent_memory` 表与 `topic` 表读取
/// （与 agent_session_provider.run 的注入来源一致）。
class _InjectedContextPanel extends ConsumerStatefulWidget {
  const _InjectedContextPanel({this.teachingTopicId});

  /// 教学模式 topic id；null=普通会话（不注入 topic_context）。
  final int? teachingTopicId;

  @override
  ConsumerState<_InjectedContextPanel> createState() =>
      _InjectedContextPanelState();
}

/// 面板异步加载的数据（一次读取，面板生命周期内保持）。
class _InjectedContextData {
  const _InjectedContextData({
    required this.memoryBlock,
    required this.topicText,
  });
  final String memoryBlock; // '<memory-context>…' 或「暂无」
  final String? topicText; // 知识点教学上下文；null=非教学模式
}

class _InjectedContextPanelState extends ConsumerState<_InjectedContextPanel> {
  bool _expanded = false;
  Future<_InjectedContextData>? _data;

  @override
  void initState() {
    super.initState();
    _data = _load();
  }

  /// 教学模式 topicId 由 AiChatPage 在首帧后经 startTopicTeaching 才写入 state，
  /// 面板首次 build 时可能还是 null——变化时重载（否则教学上下文缺失）。
  @override
  void didUpdateWidget(_InjectedContextPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.teachingTopicId != widget.teachingTopicId) {
      _data = _load();
    }
  }

  /// 与 agent_session_provider 的注入来源一致：memory 取自 agent_memory 表，
  /// topic_context 取自 topic 表 + 分类路径。
  Future<_InjectedContextData> _load() async {
    final db = await ref.read(databaseProvider.future);
    final tid = widget.teachingTopicId;
    // memory 与 topic 互不依赖，并行查询；category path 依赖 topic 结果再取。
    final (memories, topic) = await (
      AgentMemoryRepository(db).queryByScenario('study_plan'),
      tid != null ? TopicRepository(db).findById(tid) : Future.value(null),
    ).wait;
    // 与引擎 _memoryContextBlock 一致：取 content 文本拼 `[N] 内容` 编号块。
    final memoryBlock = memories.isEmpty
        ? '（暂无经验记忆，不会注入）'
        : memories.asMap().entries.map((e) => '[${e.key + 1}] ${e.value.content}').join('\n');
    String? topicText;
    if (tid != null) {
      if (topic != null) {
        final path =
            (await CategoryRepository(db).pathOf(topic.categoryId)).join('/');
        topicText = '知识点：${topic.title}（id=${topic.id}）\n'
            '分类路径：$path\n'
            '引子（背景/问题）：${topic.question}\n'
            '答案（核心内容）：${topic.summary}';
      } else {
        topicText = '（知识点 id=$tid 不存在）';
      }
    }
    return _InjectedContextData(memoryBlock: memoryBlock, topicText: topicText);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow.withValues(alpha: 0.6),
        border: Border.all(color: cs.outlineVariant, width: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Icon(Icons.science_outlined, size: 16, color: cs.primary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '已注入上下文（开发者模式）',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    color: cs.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded) ...[
            Divider(height: 1, thickness: 0.5, color: cs.outlineVariant),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              child: FutureBuilder<_InjectedContextData>(
                future: _data,
                builder: (context, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return Text(
                      '加载中…',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    );
                  }
                  final data = snap.data;
                  if (data == null) {
                    return Text(
                      '加载失败',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    );
                  }
                  final now = DateTime.now();
                  final todayStr = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _DevField(
                        label: '今日日期 {{today}}（system prompt）',
                        text: todayStr,
                        theme: theme,
                      ),
                      const SizedBox(height: 8),
                      _DevField(
                        label: '经验记忆 <memory-context>（随用户消息注入）',
                        text: data.memoryBlock,
                        theme: theme,
                      ),
                      if (data.topicText != null) ...[
                        const SizedBox(height: 8),
                        _DevField(
                          label: '知识点教学上下文 {{topic_context}}（system prompt）',
                          text: data.topicText!,
                          theme: theme,
                        ),
                      ],
                    ],
                  );
                },
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 注入上下文的单个字段：灰标签 + 等宽代码块（复用 _DevCodeBlock）。
class _DevField extends StatelessWidget {
  const _DevField({
    required this.label,
    required this.text,
    required this.theme,
  });
  final String label;
  final String text;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final cs = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: cs.onSurfaceVariant,
            fontSize: 11,
          ),
        ),
        const SizedBox(height: 4),
        _DevCodeBlock(text: text, theme: theme),
      ],
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
///
/// 设计方向：去掉 3 个功能按钮，改为一个纸感插画风格的占位图形
/// （羽毛笔 + 对话气泡 + ✦ 印章点缀），引导用户直接使用底部输入框。
/// 视觉上更克制、更有书卷气，与整体纸感学术风格一致。
class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final paper = theme.extension<PaperColors>() ?? PaperColors.light;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 纸感插画：对话气泡 + 羽毛笔 + ✦ 点缀
            _EmptyIllustration(paper: paper, cs: cs),
            const SizedBox(height: 28),
            Text(
              '开始你的问题',
              textAlign: TextAlign.center,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: cs.onSurface,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '拍照提问，或直接输入你的疑问\nAI 会陪你一起思考',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: cs.onSurfaceVariant,
                height: 1.6,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 空态插画：对话气泡 + 羽毛笔 + ✦ 印章点缀。
///
/// 用 CustomPaint 手绘，保持纸感学术风格：虚线气泡边框 + 简约羽毛笔剪影。
class _EmptyIllustration extends StatelessWidget {
  const _EmptyIllustration({required this.paper, required this.cs});

  final PaperColors paper;
  final ColorScheme cs;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 140,
      height: 120,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // 对话气泡（虚线边框，拍立得白底）
          Positioned(
            left: 0,
            top: 8,
            child: CustomPaint(
              size: const Size(100, 80),
              painter: _BubblePainter(
                color: paper.stampRed,
                bgColor: paper.polaroidBg,
              ),
            ),
          ),
          // 气泡内的 ✦ 印章
          Positioned(
            left: 38,
            top: 32,
            child: Text(
              '✦',
              style: TextStyle(
                color: paper.stampRed,
                fontSize: 22,
                height: 1.0,
              ),
            ),
          ),
          // 羽毛笔（斜放，笔尖朝向气泡）
          Positioned(
            right: 2,
            bottom: 0,
            child: Transform.rotate(
              angle: -25 * math.pi / 180,
              child: CustomPaint(
                size: const Size(44, 70),
                painter: _QuillPainter(
                  color: paper.gold,
                  tipColor: paper.stampRed,
                  highlightColor: paper.paperHighlight,
                ),
              ),
            ),
          ),
          // 小墨点装饰
          Positioned(
            right: 12,
            top: 4,
            child: Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: paper.stampRed.withValues(alpha: 0.6),
                shape: BoxShape.circle,
              ),
            ),
          ),
          Positioned(
            left: 8,
            bottom: 4,
            child: Container(
              width: 4,
              height: 4,
              decoration: BoxDecoration(
                color: paper.gold.withValues(alpha: 0.7),
                shape: BoxShape.circle,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 虚线对话气泡绘制器。
class _BubblePainter extends CustomPainter {
  _BubblePainter({required this.color, required this.bgColor});

  final Color color;
  final Color bgColor;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(0, 0, size.width, size.height - 12);
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(14));

    // 填充
    final fillPaint = Paint()..color = bgColor;
    canvas.drawRRect(rrect, fillPaint);

    // 虚线边框
    final borderPaint = Paint()
      ..color = color.withValues(alpha: 0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    _drawDashedRRect(canvas, rrect, borderPaint, 6, 4);

    // 气泡小尾巴
    final tailPath = Path()
      ..moveTo(size.width * 0.3, size.height - 12)
      ..lineTo(size.width * 0.18, size.height)
      ..lineTo(size.width * 0.42, size.height - 12)
      ..close();
    canvas.drawPath(tailPath, fillPaint);

    // 尾巴左边
    final tailLeftPaint = Paint()
      ..color = color.withValues(alpha: 0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    _drawDashedLine(
      canvas,
      Offset(size.width * 0.3, size.height - 12),
      Offset(size.width * 0.18, size.height),
      tailLeftPaint,
      4,
      3,
    );
    _drawDashedLine(
      canvas,
      Offset(size.width * 0.18, size.height),
      Offset(size.width * 0.42, size.height - 12),
      tailLeftPaint,
      4,
      3,
    );
  }

  void _drawDashedRRect(
    Canvas canvas,
    RRect rrect,
    Paint paint,
    double dash,
    double gap,
  ) {
    final path = Path()..addRRect(rrect);
    _drawDashedPath(canvas, path, paint, dash, gap);
  }

  void _drawDashedPath(
    Canvas canvas,
    Path path,
    Paint paint,
    double dash,
    double gap,
  ) {
    final metrics = path.computeMetrics().toList();
    for (final metric in metrics) {
      var distance = 0.0;
      while (distance < metric.length) {
        final len = dash;
        final extractPath = metric.extractPath(distance, distance + len);
        canvas.drawPath(extractPath, paint);
        distance += dash + gap;
      }
    }
  }

  void _drawDashedLine(
    Canvas canvas,
    Offset start,
    Offset end,
    Paint paint,
    double dash,
    double gap,
  ) {
    final path = Path()
      ..moveTo(start.dx, start.dy)
      ..lineTo(end.dx, end.dy);
    _drawDashedPath(canvas, path, paint, dash, gap);
  }

  @override
  bool shouldRepaint(covariant _BubblePainter oldDelegate) =>
      color != oldDelegate.color || bgColor != oldDelegate.bgColor;
}

/// 羽毛笔绘制器。
class _QuillPainter extends CustomPainter {
  _QuillPainter({
    required this.color,
    required this.tipColor,
    required this.highlightColor,
  });

  final Color color;
  final Color tipColor;

  /// 叶片上的浅色高光（中轴细茎 + 笔尖高光），走主题 token。
  final Color highlightColor;

  @override
  void paint(Canvas canvas, Size size) {
    // 羽毛主体（叶片形状，用贝塞尔曲线）
    final shaftPaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final featherPath = Path();
    featherPath.moveTo(size.width * 0.5, size.height * 0.15);
    featherPath.cubicTo(
      size.width * 0.9, size.height * 0.25,
      size.width * 0.95, size.height * 0.55,
      size.width * 0.55, size.height * 0.75,
    );
    featherPath.cubicTo(
      size.width * 0.2, size.height * 0.6,
      size.width * 0.1, size.height * 0.35,
      size.width * 0.5, size.height * 0.15,
    );
    canvas.drawPath(featherPath, shaftPaint);

    // 羽毛中轴（浅色细茎）—— 走主题高光 token，亮模式象牙白、暗模式深褐。
    final stemPaint = Paint()
      ..color = highlightColor.withValues(alpha: 0.6)
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(size.width * 0.5, size.height * 0.18),
      Offset(size.width * 0.48, size.height * 0.72),
      stemPaint,
    );

    // 笔尖（朱砂色，三角形）
    final tipPaint = Paint()
      ..color = tipColor
      ..style = PaintingStyle.fill;
    final tipPath = Path();
    tipPath.moveTo(size.width * 0.55, size.height * 0.72);
    tipPath.lineTo(size.width * 0.35, size.height * 0.78);
    tipPath.lineTo(size.width * 0.5, size.height);
    tipPath.close();
    canvas.drawPath(tipPath, tipPaint);

    // 笔尖高光
    final tipHighlight = Paint()
      ..color = highlightColor.withValues(alpha: 0.4)
      ..strokeWidth = 0.8
      ..style = PaintingStyle.stroke;
    canvas.drawLine(
      Offset(size.width * 0.48, size.height * 0.75),
      Offset(size.width * 0.5, size.height * 0.96),
      tipHighlight,
    );
  }

  @override
  bool shouldRepaint(covariant _QuillPainter oldDelegate) =>
      color != oldDelegate.color ||
      tipColor != oldDelegate.tipColor ||
      highlightColor != oldDelegate.highlightColor;
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
  /// 状态语义色走主题 token(tertiary=成功/墨绿、error=危险/朱砂)。
  ({String label, Color color, Color onColor}) _badge(ColorScheme cs) {
    switch (item.verdict) {
      case 'correct':
        return (label: '✓', color: cs.tertiary, onColor: cs.onTertiary);
      case 'partial':
        return (label: '◐', color: cs.error, onColor: cs.onError);
      default:
        return (label: '✗', color: cs.error, onColor: cs.onError);
    }
  }

  @override
  Widget build(BuildContext context) {
    final paper = Theme.of(context).extension<PaperColors>();
    final cs = Theme.of(context).colorScheme;
    final badge = _badge(cs);
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
                      color: badge.onColor,
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

// ─────────────────────────────────────────────────────────────
// 私有 widget：教学入口顶部知识卡（可折叠）
// ─────────────────────────────────────────────────────────────

/// 教学入口顶部知识卡：默认展开（标题 + 引子/答案缩略 2 行），可折叠成一行标题条，
/// 点卡片主体跳回知识点详情页。数据来自 TopicRepository.findById。
class _TopicHeaderCard extends ConsumerStatefulWidget {
  const _TopicHeaderCard({required this.topicId});

  final int topicId;

  @override
  ConsumerState<_TopicHeaderCard> createState() => _TopicHeaderCardState();
}

class _TopicHeaderCardState extends ConsumerState<_TopicHeaderCard> {
  bool _expanded = true;

  Future<Topic?> _loadTopic() async {
    final db = await ref.read(databaseProvider.future);
    return TopicRepository(db).findById(widget.topicId);
  }

  /// 剥掉常见 Markdown 记号，供缩略文本用。
  String _stripMarkdown(String s) =>
      s.replaceAll(RegExp(r'[*_`#>\-\[\]()]'), '').trim();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      color: cs.surfaceContainerLow,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: cs.outlineVariant, width: 0.5),
      ),
      child: FutureBuilder<Topic?>(
        future: _loadTopic(),
        builder: (context, snap) {
          final title = snap.data?.title ?? '知识点';
          return InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => context.push('/topic/${widget.topicId}'),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.emoji_objects_outlined,
                      size: 16, color: cs.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall
                                ?.copyWith(fontWeight: FontWeight.w700)),
                        if (_expanded && snap.hasData) ...[
                          const SizedBox(height: 4),
                          Text('引子：${_stripMarkdown(snap.data!.question)}',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall
                                  ?.copyWith(color: cs.onSurfaceVariant)),
                          const SizedBox(height: 2),
                          Text('答案：${_stripMarkdown(snap.data!.summary)}',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall
                                  ?.copyWith(color: cs.onSurfaceVariant)),
                        ],
                      ],
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('topic-card-toggle'),
                    visualDensity: VisualDensity.compact,
                    iconSize: 18,
                    icon: Icon(
                        _expanded ? Icons.expand_less : Icons.expand_more),
                    tooltip: _expanded ? '收起' : '展开',
                    onPressed: () =>
                        setState(() => _expanded = !_expanded),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
