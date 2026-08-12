// 占位骨架：知识点详情。Phase 5 填实（FSRS 间隔重复 + 多轮问 AI）。
// 用 PaperScaffold 保留纸感渐变底，避免裸 Scaffold 白屏。
library;

import 'package:flutter/material.dart';

import '../../core/theme/paper_scaffold.dart';

/// 知识点详情页（建设中占位）。
///
/// [topicId] 由路由 `/topic/:id` 注入；非数字 id 由 router 兜底回 /today。
class TopicDetailPage extends StatelessWidget {
  const TopicDetailPage({super.key, required this.topicId});

  final int topicId;

  @override
  Widget build(BuildContext context) {
    return PaperScaffold(
      appBar: AppBar(title: const Text('知识点')),
      body: const Center(child: Text('建设中')),
    );
  }
}
