// ask_user 提问卡片：渲染 LLM 的结构化提问，收集用户作答并回灌。
//
// 三种形态（按 request.options / multiSelect 决定）：
// - 单选：点选项立即 onSubmit(value)
// - 多选：勾选多个后点「提交 (N项)」→ onSubmit("v1, v2")
// - 自由输入（options 为空）：TextField + 「提交答案」→ onSubmit(文本)
//
// 纸感风格对齐 SavedTopicCapsule：polaroidBg 底 + ruleSoft 描边，主色走
// theme.colorScheme / paper 扩展，禁硬编码 Colors.*/Color(0x...)。
library;

import 'package:flutter/material.dart';
import 'package:study_engine/study_engine.dart';

import '../theme/paper_extension.dart';

/// LLM 向用户提问的卡片。作答后经 [onSubmit] 把答案（value 字符串/多选拼接/自由文本）
/// 回灌给挂起的 agent。
class AskUserCard extends StatefulWidget {
  const AskUserCard({super.key, required this.request, required this.onSubmit});

  final AskUserRequest request;
  final ValueChanged<String> onSubmit;

  @override
  State<AskUserCard> createState() => _AskUserCardState();
}

class _AskUserCardState extends State<AskUserCard> {
  final TextEditingController _freeInputCtrl = TextEditingController();
  final Set<String> _picked = {};

  @override
  void dispose() {
    _freeInputCtrl.dispose();
    super.dispose();
  }

  void _submitSingle(String value) => widget.onSubmit(value);

  void _submitMulti() {
    if (_picked.isEmpty) return;
    widget.onSubmit(_picked.toList().join(', '));
  }

  void _submitFree() {
    final text = _freeInputCtrl.text.trim();
    if (text.isEmpty) return;
    widget.onSubmit(text);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final paper = theme.extension<PaperColors>();
    final req = widget.request;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: paper?.polaroidBg ?? cs.surfaceContainerLow,
        border: Border(
          left: BorderSide(color: paper?.stampRed ?? cs.primary, width: 3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (req.header != null) ...[
            Text(
              req.header!,
              style: theme.textTheme.labelMedium?.copyWith(
                color: paper?.stampRed ?? cs.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
          ],
          Text(req.question, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 10),
          if (req.isFreeInput)
            _freeInput()
          else
            ..._options(),
        ],
      ),
    );
  }

  /// 选项列表（单/多选）。
  List<Widget> _options() {
    final req = widget.request;
    return [
      ...req.options.map(
        (opt) => _OptionTile(
          key: ValueKey('ask-opt-${opt.value}'),
          option: opt,
          selected: _picked.contains(opt.value),
          multiSelect: req.multiSelect,
          onTap: () {
            if (req.multiSelect) {
              setState(() {
                if (!_picked.add(opt.value)) {
                  _picked.remove(opt.value);
                }
              });
            } else {
              _submitSingle(opt.value);
            }
          },
        ),
      ),
      if (req.multiSelect) ...[
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton(
            onPressed: _picked.isEmpty ? null : _submitMulti,
            child: Text('提交（${_picked.length}项）'),
          ),
        ),
      ],
    ];
  }

  /// 自由输入形态：TextField + 提交按钮。
  Widget _freeInput() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _freeInputCtrl,
          enabled: true,
          decoration: const InputDecoration(
            hintText: '请输入答案',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          onSubmitted: (_) => _submitFree(),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton(
            onPressed: _submitFree,
            child: const Text('提交答案'),
          ),
        ),
      ],
    );
  }
}

/// 单个选项按钮：单选直接回传，多选切换勾选态。
class _OptionTile extends StatelessWidget {
  const _OptionTile({
    super.key,
    required this.option,
    required this.selected,
    required this.multiSelect,
    required this.onTap,
  });

  final AskUserOption option;
  final bool selected;
  final bool multiSelect;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? cs.primaryContainer : cs.surfaceContainerLow,
            border: Border.all(
              color: selected ? cs.primary : cs.outlineVariant,
              width: 1,
            ),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                multiSelect
                    ? (selected ? Icons.check_box : Icons.check_box_outline_blank)
                    : (selected ? Icons.radio_button_checked : Icons.radio_button_off),
                size: 20,
                color: selected ? cs.primary : cs.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      option.label,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                    if (option.description != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        option.description!,
                        style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
