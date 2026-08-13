// 应用日志查看页:纸感列表,支持级别过滤、关键词搜索、展开详情、清空、导出。
// 数据来自 LoggerService(单例,Task 6 产物),通过 logChangeNotifier 监听变更。
import 'package:flutter/material.dart';

import '../../core/services/logger_service.dart';
import '../../core/theme/paper_extension.dart';
import '../../core/theme/paper_scaffold.dart';

class AppLogViewerPage extends StatefulWidget {
  const AppLogViewerPage({super.key});
  @override
  State<AppLogViewerPage> createState() => _AppLogViewerPageState();
}

class _AppLogViewerPageState extends State<AppLogViewerPage> {
  LogLevel? _levelFilter;
  String _query = '';
  final Set<int> _expanded = {};

  @override
  void initState() {
    super.initState();
    LoggerService.logChangeNotifier.addListener(_onChanged);
  }

  @override
  void dispose() {
    LoggerService.logChangeNotifier.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  List<LogEntry> get _filtered {
    var logs = LoggerService.instance.getLogsByLevel(_levelFilter).reversed.toList();
    if (_query.isNotEmpty) {
      final q = _query.toLowerCase();
      logs = logs
          .where((l) =>
              l.message.toLowerCase().contains(q) ||
              l.tags.any((t) => t.toLowerCase().contains(q)))
          .toList();
    }
    return logs;
  }

  Color _levelColor(LogLevel l, ThemeData t) {
    switch (l) {
      case LogLevel.debug:
        return t.colorScheme.outline;
      case LogLevel.info:
        return t.colorScheme.tertiary;
      case LogLevel.warning:
        return t.extension<PaperColors>()!.gold;
      case LogLevel.error:
        return t.colorScheme.primary;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final stats = LoggerService.instance.getStatistics();
    final logs = _filtered;
    return PaperScaffold(
      appBar: AppBar(
        title: const Text('应用日志'),
        actions: [
          IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: '清空',
              onPressed: _clear),
          IconButton(
              icon: const Icon(Icons.ios_share),
              tooltip: '导出',
              onPressed: _export),
        ],
      ),
      body: Column(children: [
        Container(
          width: double.infinity,
          color: theme.colorScheme.surfaceContainerHigh.withValues(alpha: 0.5),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text(
            '共 ${stats.total} 条 · 错误 ${stats.byLevel[LogLevel.error] ?? 0}',
            style: theme.textTheme.labelSmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Wrap(
            spacing: 6,
            children: [
              for (final l in LogLevel.values)
                FilterChip(
                  label: Text(l.name),
                  selected: _levelFilter == l,
                  onSelected: (_) => setState(
                      () => _levelFilter = _levelFilter == l ? null : l),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: TextField(
            decoration: const InputDecoration(
                isDense: true,
                hintText: '搜索...',
                prefixIcon: Icon(Icons.search, size: 18)),
            onChanged: (v) => setState(() => _query = v),
          ),
        ),
        Expanded(
          child: logs.isEmpty
              ? Center(
                  child: Text('暂无日志', style: theme.textTheme.bodyMedium))
              : ListView.builder(
                  itemCount: logs.length,
                  itemBuilder: (_, i) {
                    final log = logs[i];
                    final expanded =
                        _expanded.contains(log.timestamp.millisecondsSinceEpoch);
                    return InkWell(
                      onTap: () => setState(() {
                        final k = log.timestamp.millisecondsSinceEpoch;
                        if (expanded) {
                          _expanded.remove(k);
                        } else {
                          _expanded.add(k);
                        }
                      }),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 10),
                        decoration: BoxDecoration(
                          border: Border(
                              bottom: BorderSide(
                                  color: theme
                                      .extension<PaperColors>()!
                                      .ruleSoft,
                                  width: 0.6)),
                        ),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(children: [
                                Container(
                                    width: 8,
                                    height: 8,
                                    decoration: BoxDecoration(
                                        color: _levelColor(log.level, theme),
                                        shape: BoxShape.circle)),
                                const SizedBox(width: 8),
                                Text(
                                    LoggerService.formatTimestamp(
                                        log.timestamp),
                                    style: theme.textTheme.labelSmall?.copyWith(
                                        color: theme
                                            .colorScheme.onSurfaceVariant,
                                        fontSize: 11)),
                                const SizedBox(width: 8),
                                Text('[${log.category.name}]',
                                    style: theme.textTheme.labelSmall?.copyWith(
                                        color: _levelColor(log.level, theme),
                                        fontSize: 11)),
                                const Spacer(),
                                Text(log.level.name,
                                    style: theme.textTheme.labelSmall?.copyWith(
                                        color: _levelColor(log.level, theme),
                                        fontSize: 11)),
                              ]),
                              const SizedBox(height: 4),
                              Text(log.message,
                                  maxLines: expanded ? null : 2,
                                  overflow: expanded
                                      ? TextOverflow.visible
                                      : TextOverflow.ellipsis,
                                  style: theme.textTheme.headlineSmall
                                      ?.copyWith(fontSize: 12)),
                              if (expanded && log.stackTrace != null) ...[
                                const SizedBox(height: 6),
                                Container(
                                  padding: const EdgeInsets.all(6),
                                  color: theme.colorScheme.surfaceContainerHigh
                                      .withValues(alpha: 0.6),
                                  child: SelectableText(log.stackTrace!,
                                      style: const TextStyle(
                                          fontFamily: 'monospace',
                                          fontSize: 10)),
                                ),
                              ],
                              if (expanded && log.traceId != null)
                                Padding(
                                    padding: const EdgeInsets.only(top: 4),
                                    child: Text('trace: ${log.traceId}',
                                        style: theme.textTheme.labelSmall
                                            ?.copyWith(
                                                fontSize: 10,
                                                color: theme.colorScheme
                                                    .onSurfaceVariant))),
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
              title: const Text('清空日志'),
              content: const Text('确定清空所有应用日志?此操作不可撤销。'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(c, false),
                    child: const Text('取消')),
                TextButton(
                    onPressed: () => Navigator.pop(c, true),
                    child: const Text('清空'))
              ],
            ));
    if (ok == true) await LoggerService.instance.clearLogs();
  }

  Future<void> _export() async {
    final file = await LoggerService.instance.exportToFile();
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('已导出到: ${file.path}')));
    }
  }
}
