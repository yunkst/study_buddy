import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
                onPressed: () => notifier.stop(),
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
}
