// LLM 调用详情页:展示单条 LlmCallRecord 的摘要 + 请求体 + 响应体(JSON 美化),
// 支持复制完整记录到剪贴板。数据来自 LlmLogger.getById。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/services/llm_logger/llm_call_record.dart';
import '../../core/services/llm_logger/llm_logger.dart';
import '../../core/theme/paper_scaffold.dart';

class LlmLogDetailPage extends StatefulWidget {
  final String recordId;
  const LlmLogDetailPage({super.key, required this.recordId});
  @override
  State<LlmLogDetailPage> createState() => _LlmLogDetailPageState();
}

class _LlmLogDetailPageState extends State<LlmLogDetailPage> {
  LlmCallRecord? _record;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await LlmLogger.instance.getById(widget.recordId);
    if (mounted) {
      setState(() {
        _record = r;
        _loading = false;
      });
    }
  }

  String _fmtJson(String s) {
    try {
      return const JsonEncoder.withIndent('  ').convert(jsonDecode(s));
    } catch (_) {
      return s;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PaperScaffold(
      appBar: AppBar(
        title: const Text('调用详情'),
        actions: [
          IconButton(
              icon: const Icon(Icons.copy),
              tooltip: '复制',
              onPressed: _record == null ? null : _copy)
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _record == null
              ? const Center(child: Text('未找到该记录'))
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _summary(theme, _record!),
                        const SizedBox(height: 12),
                        _section(theme, '请求体', _fmtJson(_record!.requestBody)),
                        const SizedBox(height: 12),
                        _section(theme,
                            _record!.isSuccess ? '响应体' : '响应体(失败)',
                            _responseContent(_record!)),
                        const SizedBox(height: 24),
                      ]),
                ),
    );
  }

  /// 响应内容:成功时展示响应体;失败时优先展示 errorMessage(失败请求的
  /// responseBody 常为空串,此时仅 errorMessage 承载失败原因),无信息则占位。
  String _responseContent(LlmCallRecord r) {
    final rb = r.responseBody;
    final err = r.errorMessage;
    if (r.isSuccess) {
      return (rb != null && rb.isNotEmpty) ? _fmtJson(rb) : '(无响应体)';
    }
    if (err != null && err.isNotEmpty) return err;
    if (rb != null && rb.isNotEmpty) return _fmtJson(rb);
    return '(无响应体)';
  }

  Widget _summary(ThemeData theme, LlmCallRecord r) {
    final color =
        r.isSuccess ? theme.colorScheme.tertiary : theme.colorScheme.primary;
    final rows = <(String, String)>[
      ('时间', r.timestamp.toLocal().toString().substring(0, 19)),
      ('状态', r.isSuccess ? '成功' : '失败'),
      ('模型', r.model ?? '-'),
      ('Endpoint', r.endpoint.isEmpty ? '-' : r.endpoint),
      ('流式', r.isStreaming ? '是' : '否'),
      ('耗时', r.durationText),
      ('Tokens', 'total: ${r.totalTokens ?? '-'}'),
      ('TraceId', r.traceId ?? '-'),
    ];
    return Card(
        child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        children: [
          for (int i = 0; i < rows.length; i++) ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                      width: 72,
                      child: Text(rows[i].$1,
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurface
                                  .withValues(alpha: 0.5)))),
                  Expanded(
                      child: SelectableText(rows[i].$2,
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: rows[i].$1 == '状态' ? color : null,
                              fontFamily:
                                  rows[i].$1 == 'Endpoint' ? 'monospace' : null))),
                ],
              ),
            ),
            if (i < rows.length - 1)
              Divider(
                  height: 1, color: theme.dividerColor.withValues(alpha: 0.3)),
          ]
        ],
      ),
    ));
  }

  Widget _section(ThemeData theme, String label, String content) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: theme.textTheme.labelSmall
                ?.copyWith(fontWeight: FontWeight.w600, color: theme.colorScheme.onSurfaceVariant)),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHigh
                  .withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(6)),
          constraints: const BoxConstraints(maxHeight: 360),
          child: SingleChildScrollView(
              child: SelectableText(content,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11))),
        ),
      ],
    );
  }

  Future<void> _copy() async {
    final r = _record;
    if (r == null) return;
    await Clipboard.setData(
        ClipboardData(text: const JsonEncoder.withIndent('  ').convert(r.toJson())));
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已复制完整记录')));
    }
  }
}
