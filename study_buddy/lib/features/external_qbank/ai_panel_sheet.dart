// 纸感学术 AI 面板：拍立得截图 + 用户气泡 + 工具轨迹 + AI 回复，对话式纸感。
//
// 视觉参照 `design-preview/02-paper.html` 的 `.polaroid` / `.note-user` /
// `.saved-mark` / `.ai-note` / `.input-line` / `.btn-quill`。
// 主题 token 用法与 home_page / permission_guide_page 一致。
//
// 功能不变约束（spec §F）：
// - `showAiPanel` 签名 + `showModalBottomSheet` 参数原样保留。
// - `_runAgent` agent 逻辑全保留，只在 setState 里多存一行 `_userQuery`。
// - `_aiText` StringBuffer / 事件写入 / dispose / 错误兜底三处全保留。
// - `_toolEvents` 文案格式（→ / ← / · 前缀字符串）不改。
// - engine 零改动，AI 回复解析仅 build 展示层（_buildAiTextSpan）。
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:study_engine/study_engine.dart';

import '../../core/providers/agent_session_provider.dart';
import '../../core/providers/screenshot_provider.dart';
import '../../core/theme/dashed_border.dart';
import '../../core/theme/paper_extension.dart';

/// 弹出底部抽屉：拍立得截图 + 用户输入气泡 + agent 流式回复。
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
  // 对话感关键：把本轮用户提问持久化到面板里，作为"问"气泡渲染。
  String? _userQuery;
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
      _userQuery = null; // 先清空，等拿到 userText 再赋值（见下）
    });

    final userText = _inputCtrl.text.trim().isEmpty
        ? '分析这道题涉及的知识点'
        : _inputCtrl.text.trim();
    // 把本轮提问记录下来，build 里据此渲染"问"气泡。
    setState(() => _userQuery = userText);

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
      if (!mounted) return;
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
    final theme = Theme.of(context);
    final paper = theme.extension<PaperColors>()!;
    final colorScheme = theme.colorScheme;
    // AI 回复行样式：bodyLarge 基础上加 1.95 行高，保留衬线感（bodyLarge 已是 NotoSansSC）。
    final aiBody = theme.textTheme.bodyLarge?.copyWith(height: 1.95);
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
            // 顶部抓把手：outline 主题色（硬编码 grey.shade400 已替换）。
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
            // 拍立得截图：白底 + 不对称 padding（底部留 caption）+ 倾斜 + 暖阴影 + 图钉。
            Center(
              child: _Polaroid(
                image: Image.memory(
                  widget.screenshot.pngBytes,
                  height: 100,
                  fit: BoxFit.contain,
                ),
                paper: paper,
              ),
            ),
            const SizedBox(height: 12),
            // 用户输入：删除 OutlineInputBorder 覆盖，沿用 theme 已配的下划线。
            TextField(
              controller: _inputCtrl,
              enabled: !_busy,
              decoration: const InputDecoration(
                labelText: '补充说明（可选）',
                hintText: '例如：解析思路',
                isDense: true,
              ),
              maxLines: 2,
            ),
            const SizedBox(height: 8),
            // 提交按钮：FilledButton.icon + 羽毛笔 icon（theme 已配墨黑底纸白字）。
            FilledButton.icon(
              onPressed: _busy ? null : _runAgent,
              icon: Icon(
                _busy ? Icons.hourglass_top : Icons.edit_note,
                size: 18,
              ),
              label: Text(_busy ? '分析中...' : '开始分析'),
            ),
            // 用户气泡：只在已发起本轮分析后渲染。
            if (_userQuery != null) ...[
              const SizedBox(height: 12),
              _UserBubble(query: _userQuery!, colorScheme: colorScheme, theme: theme),
            ],
            // 错误展示：errorContainer 底 + onErrorContainer 文字 + 朱砂左边框。
            if (_errorText != null) ...[
              const SizedBox(height: 12),
              _ErrorPanel(text: _errorText!, colorScheme: colorScheme, theme: theme),
            ],
            // 工具调用轨迹：surfaceContainerHigh 容器 + titleSmall 标题 + ※ 装饰。
            if (_toolEvents.isNotEmpty) ...[
              const SizedBox(height: 12),
              _ToolTrace(
                events: _toolEvents,
                saved: _saved,
                colorScheme: colorScheme,
                theme: theme,
              ),
            ],
            // AI 回复：surfaceContainerLow 容器 + bodyLarge height1.95 + 知识点行解析。
            if (_aiText.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text('AI 回复', style: theme.textTheme.titleSmall),
              const SizedBox(height: 6),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerLow,
                ),
                child: SelectableText.rich(
                  _buildAiTextSpan(_aiText.toString(), aiBody, colorScheme),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// AI 回复解析：以 `※` / `-` / `·` 开头的行加朱砂 ※ 前缀，其余原样输出。
  /// 仅展示层处理，不动 _aiText 字符串内容。
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
        children.add(TextSpan(text: '$trimmed\n', style: aiBody));
      } else {
        children.add(TextSpan(text: '$line\n', style: aiBody));
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
  const _Polaroid({required this.image, required this.paper});

  final Widget image;
  final PaperColors paper;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Transform.rotate(
      angle: -1.5 * math.pi / 180,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(10, 10, 10, 26),
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
class _ToolTrace extends StatelessWidget {
  const _ToolTrace({
    required this.events,
    required this.saved,
    required this.colorScheme,
    required this.theme,
  });

  final List<String> events;
  final bool saved;
  final ColorScheme colorScheme;
  final ThemeData theme;

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
                    child: Text(e, style: theme.textTheme.bodySmall),
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
