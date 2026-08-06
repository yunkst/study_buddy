import 'package:flutter/material.dart';

/// 右下角悬浮 AI 助手按钮。父组件通过 Stack 覆盖在 QbankWebView 上方。
class FloatingAiButton extends StatelessWidget {
  const FloatingAiButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      right: 16,
      bottom: 24,
      child: Material(
        color: Theme.of(context).colorScheme.primary,
        shape: const CircleBorder(),
        elevation: 6,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: const SizedBox(
            width: 56,
            height: 56,
            child: Icon(Icons.smart_toy_outlined, color: Colors.white, size: 28),
          ),
        ),
      ),
    );
  }
}
