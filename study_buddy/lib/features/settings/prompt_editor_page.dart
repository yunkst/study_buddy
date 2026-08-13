// 提示词设置页：编辑「学习伴侣」场景的 system prompt 运行时覆盖。
//
// - 默认加载引擎内置模板（kStudyPlanSystemPromptTemplate 同款内容），可在其上修改；
// - 保存 → upsert 到 prompt_override 表（agent_session_provider 下次 run() 生效）；
// - 「恢复默认」→ 删除覆盖，回落到引擎内置模板。
// 占位符 {{today}} / {{plan_summary}} 保留，运行时会填充。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:study_engine/study_engine.dart';

import '../../core/providers/database_provider.dart';
import '../../core/theme/paper_extension.dart';
import '../../core/theme/paper_scaffold.dart';

class PromptEditorPage extends ConsumerStatefulWidget {
  const PromptEditorPage({super.key, this.scenarioId = 'study_plan'});
  final String scenarioId;

  @override
  ConsumerState<PromptEditorPage> createState() => _PromptEditorPageState();
}

class _PromptEditorPageState extends ConsumerState<PromptEditorPage> {
  late final TextEditingController _controller;
  String? _basePrompt; // 引擎默认模板（用于「恢复默认」提示）
  bool _loaded = false;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
    _load();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final db = await ref.read(databaseProvider.future);
    final repo = PromptOverrideRepository(db);
    // 基线 = 引擎内置原始模板（含 {{today}}/{{plan_summary}} 占位符，未填充）。
    final base = kStudyPlanSystemPromptTemplate;
    final override = await repo.get(widget.scenarioId);
    if (!mounted) return;
    setState(() {
      _basePrompt = base;
      _controller.text = override ?? base;
      _loaded = true;
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final db = await ref.read(databaseProvider.future);
      final repo = PromptOverrideRepository(db);
      final content = _controller.text.trim();
      if (content.isEmpty) {
        setState(() => _error = '提示词不能为空');
        _saving = false;
        return;
      }
      await repo.upsert(widget.scenarioId, content);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已保存，下次对话生效')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '保存失败: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _resetDefault() async {
    final db = await ref.read(databaseProvider.future);
    final repo = PromptOverrideRepository(db);
    await repo.delete(widget.scenarioId);
    final base = _basePrompt ?? '';
    if (!mounted) return;
    setState(() => _controller.text = base);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已恢复内置默认提示词')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PaperScaffold(
      appBar: AppBar(title: const Text('提示词设置')),
      body: SafeArea(
        child: !_loaded
            ? const Center(child: CircularProgressIndicator())
            : Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '编辑「学习伴侣」的系统提示词。运行时覆盖：不发版即可调 prompt。',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '占位符 {{today}}（当前日期）、{{plan_summary}}（当前计划概览）会在运行时自动填充。'
                      '经验记忆通过 <memory-context> 随用户消息注入，无需写在此处。',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.extension<PaperColors>()?.ruleSoft,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        maxLines: null,
                        expands: true,
                        textAlignVertical: TextAlignVertical.top,
                        style: const TextStyle(fontSize: 13, height: 1.5),
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          hintText: '在此编辑系统提示词…',
                        ),
                      ),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 8),
                      Text(_error!,
                          style: TextStyle(color: theme.colorScheme.error)),
                    ],
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        OutlinedButton(
                          onPressed: _saving ? null : _resetDefault,
                          child: const Text('恢复默认'),
                        ),
                        const Spacer(),
                        FilledButton(
                          onPressed: _saving ? null : _save,
                          child: Text(_saving ? '保存中…' : '保存'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}
