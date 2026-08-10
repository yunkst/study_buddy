import 'package:flutter/material.dart';

import '../../../main.dart' show PendingScreenshotStore;
import '../../features/external_qbank/ai_panel_sheet.dart';
import '../knowledge/knowledge_base_page.dart';
import '../review/review_page.dart';
import 'home_page.dart';

/// 应用主壳：底部三 Tab（知识库 / 背诵 / 悬浮窗）。
class MainShell extends StatefulWidget {
  const MainShell({super.key});
  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    // 冷启动降级：弹出待处理截图的 AI 面板（原 HomePage 的 _consumePendingScreenshot 移此，
    // 避免 MainShell 与 HomePage 双消费）
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final pending = PendingScreenshotStore.pending;
      if (pending != null && mounted) {
        PendingScreenshotStore.pending = null;
        await showAiPanel(context, screenshot: pending);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: const [
          KnowledgeBasePage(),
          ReviewPage(),
          HomePage(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.menu_book_outlined),
            selectedIcon: Icon(Icons.menu_book),
            label: '知识库',
          ),
          NavigationDestination(
            icon: Icon(Icons.style_outlined),
            selectedIcon: Icon(Icons.style),
            label: '背诵',
          ),
          NavigationDestination(
            icon: Icon(Icons.screenshot_monitor_outlined),
            selectedIcon: Icon(Icons.screenshot_monitor),
            label: '悬浮窗',
          ),
        ],
      ),
    );
  }
}
