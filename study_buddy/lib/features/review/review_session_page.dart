// 占位骨架：复习会话。后续 Phase 填实（FSRS 间隔重复卡片流）。
// 用 PaperScaffold 保留纸感渐变底，避免裸 Scaffold 白屏。
library;

import 'package:flutter/material.dart';

import '../../core/theme/paper_scaffold.dart';

/// 复习会话页（建设中占位）。
class ReviewSessionPage extends StatelessWidget {
  const ReviewSessionPage({super.key});

  @override
  Widget build(BuildContext context) {
    return PaperScaffold(
      appBar: AppBar(title: const Text('复习')),
      body: const Center(child: Text('建设中')),
    );
  }
}
