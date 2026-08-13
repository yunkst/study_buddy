// LLM 调用日志列表页:纸感列表,展示模型/流式/预览/耗时,支持刷新与清空。
// 数据来自 LlmLogger(Task 7 单例),通过 changeNotifier 监听变更。
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/services/llm_logger/llm_call_record.dart';
import '../../core/services/llm_logger/llm_logger.dart';
import '../../core/theme/paper_extension.dart';
import '../../core/theme/paper_scaffold.dart';

class LlmLogViewerPage extends StatefulWidget {
  const LlmLogViewerPage({super.key});
  @override
  State<LlmLogViewerPage> createState() => _LlmLogViewerPageState();
}

class _LlmLogViewerPageState extends State<LlmLogViewerPage> {
  List<LlmCallRecord> _records = [];
  int _totalSize = 0;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
    LlmLogger.changeNotifier.addListener(_onChanged);
  }

  @override
  void dispose() {
    LlmLogger.changeNotifier.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final list = await LlmLogger.instance.getRecent(limit: 200);
    final size = await LlmLogger.instance.getTotalSize();
    if (mounted) {
      setState(() {
        _records = list;
        _totalSize = size;
        _loading = false;
      });
    }
  }

  String _sizeStr(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)}MB';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PaperScaffold(
      appBar: AppBar(
        title: const Text('LLM 调用日志'),
        actions: [
          IconButton(
              icon: const Icon(Icons.refresh), tooltip: '刷新', onPressed: _load),
          IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: '清空',
              onPressed: _clear),
        ],
      ),
      body: Column(children: [
        Container(
          width: double.infinity,
          color: theme.colorScheme.surfaceContainerHigh.withValues(alpha: 0.5),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text(
            '共 ${_records.length} 条 · 占用 ${_sizeStr(_totalSize)}${_loading ? ' · 加载中...' : ''}',
            style: theme.textTheme.labelSmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
        Expanded(
          child: _records.isEmpty
              ? Center(
                  child: Text('暂无 LLM 调用记录', style: theme.textTheme.bodyMedium))
              : ListView.builder(
                  itemCount: _records.length,
                  itemBuilder: (_, i) {
                    final r = _records[i];
                    final ok = r.isSuccess;
                    final color =
                        ok ? theme.colorScheme.tertiary : theme.colorScheme.primary;
                    return InkWell(
                      onTap: () => context.push('/logs/llm/${r.id}'),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 10),
                        decoration: BoxDecoration(
                          border: Border(
                              bottom: BorderSide(
                                  color: theme.extension<PaperColors>()!.ruleSoft,
                                  width: 0.6)),
                        ),
                        child: Row(children: [
                          Icon(ok ? Icons.check_circle : Icons.error,
                              color: color, size: 20),
                          const SizedBox(width: 10),
                          Expanded(
                              child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                Row(children: [
                                  if (r.model != null)
                                    Flexible(
                                        child: Text(r.model!,
                                            style: theme.textTheme.bodySmall?.copyWith(
                                                fontFamily: 'monospace',
                                                fontWeight: FontWeight.w600),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis)),
                                  if (r.isStreaming)
                                    Container(
                                        margin: const EdgeInsets.only(left: 6),
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 4, vertical: 1),
                                        decoration: BoxDecoration(
                                            color:
                                                theme.colorScheme.primaryContainer,
                                            borderRadius:
                                                BorderRadius.circular(4)),
                                        child: Text('流式',
                                            style: theme.textTheme.labelSmall
                                                ?.copyWith(fontSize: 10))),
                                ]),
                                const SizedBox(height: 2),
                                Text(r.previewText,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                        color: theme.colorScheme.onSurface
                                            .withValues(alpha: 0.7)),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis),
                                const SizedBox(height: 2),
                                Text(
                                    '${r.durationText} · tokens: ${r.totalTokens ?? '-'}',
                                    style: theme.textTheme.labelSmall?.copyWith(
                                        fontSize: 11,
                                        color: theme.colorScheme.onSurfaceVariant)),
                              ])),
                          const Icon(Icons.chevron_right, size: 18),
                        ]),
                      ),
                    );
                  },
                ),
        ),
      ]),
    );
  }

  Future<void> _clear() async {
    final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
              title: const Text('清空 LLM 日志'),
              content: const Text('确定清空所有 LLM 调用日志?'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(c, false),
                    child: const Text('取消')),
                TextButton(
                    onPressed: () => Navigator.pop(c, true),
                    child: const Text('清空'))
              ],
            ));
    if (ok == true) {
      await LlmLogger.instance.clear();
      await _load();
    }
  }
}
