import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:study_engine/study_engine.dart';

import '../../core/providers/database_provider.dart';
import '../../core/providers/focus_session_provider.dart';
import '../../core/theme/paper_scaffold.dart';

/// 专注时钟页：大号计时显示 + 开始/结束按钮 + 状态提示文案。
class FocusPage extends ConsumerWidget {
  const FocusPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(focusSessionProvider);
    final notifier = ref.read(focusSessionProvider.notifier);

    final h = state.elapsed.inHours.toString().padLeft(2, '0');
    final m = (state.elapsed.inMinutes % 60).toString().padLeft(2, '0');
    final s = (state.elapsed.inSeconds % 60).toString().padLeft(2, '0');

    return PaperScaffold(
      appBar: AppBar(title: const Text('专注时钟')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '$h:$m:$s',
              style: TextStyle(
                fontSize: 64,
                fontWeight: FontWeight.w300,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              state.running ? '专注中…' : '准备好就开始吧',
              style: TextStyle(color: Colors.grey.shade600),
            ),
            const SizedBox(height: 32),
            if (state.running)
              FilledButton.icon(
                icon: const Icon(Icons.stop),
                label: const Text('结束专注'),
                onPressed: () => _onStop(context, ref, notifier, state.sessionId),
              )
            else
              FilledButton.icon(
                icon: const Icon(Icons.play_arrow),
                label: const Text('开始专注'),
                onPressed: () => notifier.start(),
              ),
          ],
        ),
      ),
    );
  }

  /// 结束专注：弹框收集「这段时间做了什么」，写入会话摘要后再走完整 stop 流程。
  ///
  /// 仅 App 内按钮触发弹框；通知栏反向 onStopped 走裸 stop 不弹框（不打扰用户）。
  /// [sessionId] 来自当前 state（专注进行中非 null，stop 未执行），用于在
  /// stop 清空 state 前把摘要写到正确的会话记录上。
  Future<void> _onStop(
    BuildContext context,
    WidgetRef ref,
    FocusSessionNotifier notifier,
    int? sessionId,
  ) async {
    final summary = await showDialog<String>(
      context: context,
      builder: (_) => const _SummaryDialog(),
    );
    // 用户点「保存」且有非空文本 → 写库。跳过/取消/外部关闭(summary 为 null)不写。
    final text = summary?.trim() ?? '';
    if (sessionId != null && text.isNotEmpty) {
      final db = await ref.read(databaseProvider.future);
      final repo = FocusSessionRepository(db);
      await repo.setSummary(sessionId, text);
    }
    await notifier.stop();
  }
}

/// 「这段时间做了什么」输入对话框。
///
/// showDialog 的返回值：点「保存」返回输入文本（可能为空串，由调用方 trim 判断
/// 是否写入）；点「跳过」或点外部/返回键关闭（isDismissible 默认 true）返回 null。
class _SummaryDialog extends StatefulWidget {
  const _SummaryDialog();

  @override
  State<_SummaryDialog> createState() => _SummaryDialogState();
}

class _SummaryDialogState extends State<_SummaryDialog> {
  final TextEditingController _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('这段时间做了什么？'),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        maxLines: 4,
        maxLength: 500,
        decoration: const InputDecoration(
          hintText: '例如：复习了极限的洛必达法则，做完了一套高数题',
          border: OutlineInputBorder(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('跳过'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_ctrl.text),
          child: const Text('保存'),
        ),
      ],
    );
  }
}