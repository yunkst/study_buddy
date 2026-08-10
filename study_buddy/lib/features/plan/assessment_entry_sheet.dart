import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:study_engine/study_engine.dart';

import '../../core/providers/plan_provider.dart';

/// 弹出录分弹窗。返回 true 表示已录入（调用方应刷新 planDetailProvider）。
Future<bool?> showAssessmentEntry(BuildContext context, int planId) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _AssessmentEntrySheet(planId: planId),
  );
}

class _AssessmentEntrySheet extends ConsumerStatefulWidget {
  const _AssessmentEntrySheet({required this.planId});
  final int planId;

  @override
  ConsumerState<_AssessmentEntrySheet> createState() => _AssessmentEntrySheetState();
}

class _AssessmentEntrySheetState extends ConsumerState<_AssessmentEntrySheet> {
  final _scoreCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();
  DateTime _date = DateTime.now();
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _scoreCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final raw = _scoreCtrl.text.trim();
    final score = int.tryParse(raw);
    if (raw.isEmpty || score == null) {
      setState(() => _error = '请输入有效分数');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final repo = await ref.read(planRepositoryAsyncProvider.future);
    try {
      await repo.addAssessment(Assessment(
        planId: widget.planId,
        score: score,
        note: _noteCtrl.text.trim().isEmpty ? null : _noteCtrl.text.trim(),
        assessedAt: _date,
        createdAt: DateTime.now(),
      ));
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '保存失败，请重试';
        });
      }
      return;
    }
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    return Padding(
      padding: EdgeInsets.only(left: 16, right: 16, top: 12, bottom: mq.viewInsets.bottom + 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(width: 40, height: 4, margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(color: Colors.grey.shade400, borderRadius: BorderRadius.circular(2))),
          ),
          const Text('记录测评', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          TextField(
            controller: _scoreCtrl,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: '分数', border: OutlineInputBorder(), isDense: true),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _noteCtrl,
            decoration: const InputDecoration(labelText: '备注（可选）', border: OutlineInputBorder(), isDense: true),
            maxLines: 2,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text('日期：${_date.year}-${_date.month.toString().padLeft(2, '0')}-${_date.day.toString().padLeft(2, '0')}'),
              const SizedBox(width: 8),
              TextButton.icon(
                icon: const Icon(Icons.calendar_today, size: 16),
                label: const Text('改'),
                onPressed: _saving
                    ? null
                    : () async {
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: _date,
                          firstDate: DateTime(2020),
                          lastDate: DateTime(2100),
                        );
                        if (picked != null && mounted) setState(() => _date = picked);
                      },
              ),
            ],
          ),
          if (_error != null)
            Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: TextStyle(color: Colors.red.shade900, fontSize: 12))),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: Text(_saving ? '保存中...' : '保存'),
          ),
        ],
      ),
    );
  }
}
