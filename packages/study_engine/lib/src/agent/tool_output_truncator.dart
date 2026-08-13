import 'dart:io';

/// 工具输出截断（opencode truncate 风格）：超长 tool 结果不直接丢，落临时文件，
/// 返回「已写入 path + 前缀预览」，给 LLM 一个可追溯的指针。
///
/// [tmpDir] 为 null（默认，测试环境）时不截断——原样返回，避免测试依赖文件系统。
/// [maxChars] 默认 4000；超长才落盘。
String truncateToolOutput(
  String result, {
  int maxChars = 4000,
  String? tmpDir,
}) {
  if (tmpDir == null || result.length <= maxChars) return result;
  final stamp = DateTime.now().microsecondsSinceEpoch;
  final path = '$tmpDir${Platform.pathSeparator}agent-tool-$stamp.txt';
  try {
    File(path).writeAsStringSync(result, flush: true);
  } catch (_) {
    // 落盘失败（磁盘满/权限）：退化为「只给预览」，不抛——别让截断本身杀死 agent。
    return '...(工具输出过长 ${result.length} 字，临时文件写入失败，仅展示前 $maxChars 字)\n${result.substring(0, maxChars)}';
  }
  return '...(工具输出过长 ${result.length} 字，已写入临时文件 $path；如需完整内容请读取该文件)\n'
      '前 $maxChars 字预览:\n${result.substring(0, maxChars)}';
}
