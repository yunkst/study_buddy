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
