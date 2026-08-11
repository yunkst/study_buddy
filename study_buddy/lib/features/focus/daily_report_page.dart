import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:study_engine/study_engine.dart';

import '../../core/providers/database_provider.dart';

class DailyReportPage extends ConsumerStatefulWidget {
  /// 可空：为空时默认展示「今天」。const 构造函数不能调用 DateTime.now()，
  /// 故默认日期在 State 初始化时计算（见 _DailyReportPageState._today）。
  final DateTime? initialDate;
  const DailyReportPage({super.key, this.initialDate});

  @override
  ConsumerState<DailyReportPage> createState() => _DailyReportPageState();
}

class _DailyReportPageState extends ConsumerState<DailyReportPage> {
  late DateTime _date = widget.initialDate ?? _today;
  Future<DailyReport>? _reportFuture;

  static DateTime get _today {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _reportFuture = _build();
  }

  Future<DailyReport> _build() async {
    final db = await ref.read(databaseProvider.future);
    return buildDailyReport(
      focusRepo: FocusSessionRepository(db),
      topicRepo: TopicRepository(db),
      date: _date,
    );
  }

  void _changeDay(int delta) {
    setState(() {
      _date = _date.add(Duration(days: delta));
      _load();
    });
  }

  String _fmtDuration(int ms) {
    final h = ms ~/ 3600000;
    final m = (ms % 3600000) ~/ 60000;
    if (h == 0) return '$m分钟';
    if (m == 0) return '$h小时';
    return '$h小时$m分';
  }

  String _fmtTime(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${_date.month}月${_date.day}日 学习日报'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: FutureBuilder<DailyReport>(
        future: _reportFuture,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final report = snap.data!;
          if (report.sessions.isEmpty) {
            return const Center(child: Text('这天没有专注记录'));
          }
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                child: ListTile(
                  leading: const Icon(Icons.timer, color: Colors.deepPurple),
                  title: const Text('总专注用时'),
                  subtitle: Text(_fmtDuration(report.totalDurationMs),
                      style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                ),
              ),
              const SizedBox(height: 8),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Text('专注会话', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
              ...report.sessions.map((s) {
                final start = s.session.startedAt;
                final end = s.session.endedAt;
                final range = end != null
                    ? '${_fmtTime(start)}–${_fmtTime(end)}'
                    : '${_fmtTime(start)}–进行中';
                return Card(
                  child: ListTile(
                    leading: const Icon(Icons.schedule),
                    title: Text(range),
                    subtitle: Text(_fmtDuration(s.session.durationMs ?? 0)),
                  ),
                );
              }),
              const SizedBox(height: 8),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Text('今天学过的知识点', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
              ...report.uniqueTopics.map((t) => Card(
                    child: ListTile(
                      leading: const Icon(Icons.lightbulb_outline, color: Colors.amber),
                      title: Text(t.title),
                    ),
                  )),
            ],
          );
        },
      ),
      bottomNavigationBar: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            TextButton.icon(
              icon: const Icon(Icons.chevron_left),
              label: const Text('前一天'),
              onPressed: () => _changeDay(-1),
            ),
            TextButton.icon(
              icon: const Icon(Icons.chevron_right),
              label: const Text('后一天'),
              onPressed: () => _changeDay(1),
            ),
          ],
        ),
      ),
    );
  }
}
