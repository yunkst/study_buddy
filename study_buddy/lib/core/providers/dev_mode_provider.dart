import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 开发者模式开关：开启后在 AI 对话页显示工具调用详情卡片与隐式注入的上下文
/// （memory-context / system prompt 动态字段），便于调试 LLM 实际收到什么。
/// 持久化到 SharedPreferences（key='dev_mode_enabled'），跨启动保留。
final devModeProvider = AsyncNotifierProvider<DevModeNotifier, bool>(
  DevModeNotifier.new,
);

class DevModeNotifier extends AsyncNotifier<bool> {
  static const _key = 'dev_mode_enabled';

  @override
  Future<bool> build() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_key) ?? false;
  }

  /// 写入并立即更新 state，驱动设置页开关与对话页重建。
  /// 不走 invalidateSelf，避免一次多余的重读。
  Future<void> set(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, enabled);
    state = AsyncData(enabled);
  }
}
