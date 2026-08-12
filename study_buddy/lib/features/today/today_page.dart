// 占位骨架：今日 Tab。Phase 4 填实（学习闭环卡片 + 拍题入口）。
// 用 PaperScaffold 保留纸感渐变底，避免裸 Scaffold 白屏。
library;

import 'package:flutter/material.dart';

import '../../core/theme/paper_scaffold.dart';

/// 今日 Tab 根页（建设中占位）。
class TodayPage extends StatelessWidget {
  const TodayPage({super.key});

  @override
  Widget build(BuildContext context) {
    return PaperScaffold(
      appBar: AppBar(title: const Text('今日')),
      body: const Center(child: Text('建设中')),
    );
  }
}
