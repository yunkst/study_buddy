import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// 包装 InAppWebView，加载 study.keyky.cn 题库页。
/// 父组件通过 [onControllerReady] 拿到 controller 以触发截图。
class QbankWebView extends StatefulWidget {
  const QbankWebView({super.key, required this.onControllerReady});

  final ValueChanged<InAppWebViewController> onControllerReady;

  @override
  State<QbankWebView> createState() => _QbankWebViewState();
}

class _QbankWebViewState extends State<QbankWebView> {
  InAppWebViewController? _controller;
  double _progress = 0;

  /// 暴露 controller，供父组件（通过 GlobalKey 或 callback）触发截图。
  InAppWebViewController? get controller => _controller;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        InAppWebView(
          initialUrlRequest: URLRequest(url: WebUri('https://study.keyky.cn/h5/')),
          initialSettings: InAppWebViewSettings(
            javaScriptEnabled: true,
            domStorageEnabled: true,
            supportZoom: false,
            // 允许混合内容（网站可能含 http 资源）
            mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
            // 透明背景，让 host Scaffold 的颜色透出来
            transparentBackground: true,
          ),
          onWebViewCreated: (controller) {
            _controller = controller;
            widget.onControllerReady(controller);
          },
          onProgressChanged: (controller, progress) {
            if (mounted) setState(() => _progress = progress / 100.0);
          },
        ),
        if (_progress < 1.0)
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: LinearProgressIndicator(minHeight: 2),
          ),
      ],
    );
  }
}
