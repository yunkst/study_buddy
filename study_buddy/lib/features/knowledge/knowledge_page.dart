// 占位骨架：知识 Tab。Phase 5 填实（知识点列表 + 详情入口）。
// 用 PaperScaffold 保留纸感渐变底，避免裸 Scaffold 白屏。
library;

import 'package:flutter/material.dart';

import '../../core/theme/paper_scaffold.dart';

/// 知识 Tab 根页（建设中占位）。
class KnowledgePage extends StatelessWidget {
  const KnowledgePage({super.key});

  @override
  Widget build(BuildContext context) {
    return PaperScaffold(
      appBar: AppBar(title: const Text('知识')),
      body: const Center(child: Text('建设中')),
    );
  }
}
