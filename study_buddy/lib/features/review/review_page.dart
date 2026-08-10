import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:study_engine/study_engine.dart';

import '../../core/providers/knowledge_providers.dart';

class ReviewPage extends ConsumerStatefulWidget {
  const ReviewPage({super.key});
  @override
  ConsumerState<ReviewPage> createState() => _ReviewPageState();
}

class _ReviewPageState extends ConsumerState<ReviewPage> {
  ReviewMode _mode = ReviewMode.todayNew;
  List<ReviewQueueItem> _queue = [];
  ReviewQueueItem? _current;
  bool _revealed = false;
  String _answerText = ''; // 揭晓时从 topic 拉取的答案正文
  bool _loading = true;
  String? _error;
  int _remembered = 0, _forgot = 0, _easy = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final repo = await ref.read(reviewQueueRepositoryProvider.future);
      final now = DateTime.now();
      final day = DateTime(now.year, now.month, now.day);
      final q = _mode == ReviewMode.todayNew
          ? await repo.todayNewQueue(day)
          : await repo.dueQueue(now);
      if (!mounted) return;
      setState(() {
        _queue = q;
        _current = q.isEmpty ? null : q.first;
        _revealed = false;
        _answerText = '';
        _remembered = 0;
        _forgot = 0;
        _easy = 0;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  /// 揭晓答案：从 topic 表拉取答案正文。拉取失败回退标题并提示。
  Future<void> _reveal() async {
    final item = _current;
    if (item == null) return;
    try {
      final topics = await ref.read(topicRepositoryProvider.future);
      final topic = await topics.findById(item.topicId);
      if (!mounted) return;
      setState(() {
        _answerText = topic?.summary ?? item.title;
        _revealed = true;
      });
      if (topic == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('知识点不存在，已回退显示标题')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _answerText = item.title; // 拉取失败回退标题，卡仍可推进
        _revealed = true;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('加载答案失败: $e')),
      );
    }
  }

  Future<void> _submit(ReviewFeedback feedback) async {
    final item = _current;
    if (item == null) return;
    try {
      final schedRepo = await ref.read(reviewScheduleRepositoryProvider.future);
      final now = DateTime.now();
      final prev = await schedRepo.getByTopic(item.topicId);
      final base = prev ?? SpacedRepetitionService.initial(item.topicId, now);
      final next = SpacedRepetitionService.apply(base, feedback, now);
      await schedRepo.upsert(next);
      if (!mounted) return;
      setState(() {
        switch (feedback) {
          case ReviewFeedback.remembered:
            _remembered++;
            break;
          case ReviewFeedback.forgot:
            _forgot++;
            break;
          case ReviewFeedback.easy:
            _easy++;
            break;
        }
        _queue = _queue.sublist(1);
        _current = _queue.isEmpty ? null : _queue.first;
        _revealed = false;
        _answerText = '';
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存复习记录失败: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('背诵')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: SegmentedButton<ReviewMode>(
              segments: const [
                ButtonSegment(
                  value: ReviewMode.todayNew,
                  label: Text('今日新增'),
                  icon: Icon(Icons.fiber_new),
                ),
                ButtonSegment(
                  value: ReviewMode.due,
                  label: Text('到期复习'),
                  icon: Icon(Icons.schedule),
                ),
              ],
              selected: {_mode},
              onSelectionChanged: (s) {
                if (s.first == _mode) return;
                setState(() => _mode = s.first);
                _load();
              },
            ),
          ),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('加载失败: $_error'),
            const SizedBox(height: 8),
            FilledButton(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }
    if (_current == null) {
      if (_remembered + _forgot + _easy == 0) {
        // 空状态：还没开始背
        return Center(
          child: Text(
            _mode == ReviewMode.todayNew ? '今天还没有新增知识点' : '今日已背完 🎉',
            style: const TextStyle(color: Colors.grey),
          ),
        );
      }
      // 本轮统计
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('本轮背诵完成', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            Text('共 ${_remembered + _forgot + _easy} 张'),
            Text('记得 $_remembered · 忘了 $_forgot · 轻松 $_easy'),
            const SizedBox(height: 16),
            FilledButton(onPressed: _load, child: const Text('再来一轮')),
          ],
        ),
      );
    }
    // 卡片
    final item = _current!;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('第 ${_queue.length} 张剩余',
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 16),
              Text(item.question,
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 24),
              if (_revealed) ...[
                const Divider(),
                const SizedBox(height: 8),
                Text('答案', style: const TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                SelectableText(_answerText),
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.tonal(
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.red.shade100,
                        ),
                        onPressed: () => _submit(ReviewFeedback.forgot),
                        child: const Text('忘了'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton(
                        onPressed: () => _submit(ReviewFeedback.remembered),
                        child: const Text('记得'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton.tonal(
                        onPressed: () => _submit(ReviewFeedback.easy),
                        child: const Text('轻松'),
                      ),
                    ),
                  ],
                ),
              ] else
                FilledButton(
                  onPressed: _reveal,
                  child: const Text('揭晓答案'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
