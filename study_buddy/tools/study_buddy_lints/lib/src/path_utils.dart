// 规则豁免判断:主题定义处与日志服务自身允许使用字面量/Colors./fontFamily/debugPrint。

/// 主题目录:Color 字面量、Colors.*、fontFamily 的「定义处」,豁免。
bool isThemeFile(String path) {
  final p = path.replaceAll('\\', '/');
  return p.contains('/lib/core/theme/');
}

/// 日志服务目录:debugPrint 的「兜底定义处」(日志服务自身失败时不能再调自己),豁免。
bool isLoggerFile(String path) {
  final p = path.replaceAll('\\', '/');
  return p.contains('/lib/core/services/logger_service.dart') ||
      p.contains('/lib/core/services/llm_logger/');
}

/// 测试目录:断言主题 token 值(Color(0x…))是测试的本体,改成 token 引用会自证失效,豁免。
bool isTestFile(String path) {
  final p = path.replaceAll('\\', '/');
  return p.contains('/test/');
}

/// 分享导出卡片:小红书分享图用固定亮色「日光纸」色值/字体的硬编码,不读 Theme,
/// 保证导出 PNG 不受系统暗色模式影响(见 share_card_widget.dart 顶部注释),豁免。
bool isExportCardFile(String path) {
  final p = path.replaceAll('\\', '/');
  return p.contains('/lib/features/share/share_card_widget.dart');
}

/// 是否属于上述任一豁免场景(主题/日志/测试断言/导出卡片)。
bool isExemptFile(String path) =>
    isThemeFile(path) || isLoggerFile(path) || isTestFile(path) || isExportCardFile(path);

