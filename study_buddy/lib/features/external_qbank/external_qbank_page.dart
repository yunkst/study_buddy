import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/webview_screenshot_provider.dart';
import 'ai_panel_sheet.dart';
import 'floating_ai_button.dart';
import 'qbank_web_view.dart';

class ExternalQbankPage extends ConsumerStatefulWidget {
  const ExternalQbankPage({super.key});

  @override
  ConsumerState<ExternalQbankPage> createState() => _ExternalQbankPageState();
}

class _ExternalQbankPageState extends ConsumerState<ExternalQbankPage> {
  InAppWebViewController? _controller;

  Future<void> _onAiButtonPressed() async {
    final ctrl = _controller;
    if (ctrl == null) {
      _toast('页面还未加载完成，请稍候');
      return;
    }
    final service = ref.read(webViewScreenshotServiceProvider);
    final shot = await service.capture(ctrl);
    if (!mounted) return;
    if (shot == null) {
      _toast('截图失败，请稍候再试');
      return;
    }
    await showAiPanel(context, screenshot: shot);
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('题库'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: Stack(
        children: [
          QbankWebView(
            onControllerReady: (c) => _controller = c,
          ),
          FloatingAiButton(onPressed: _onAiButtonPressed),
        ],
      ),
    );
  }
}
