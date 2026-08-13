import 'dart:io';

import 'package:analyzer/error/error.dart' hide LintCode;
import 'package:analyzer/error/listener.dart';
import 'package:custom_lint_builder/custom_lint_builder.dart';

import '../path_utils.dart';

/// 禁止业务代码裸用 `dart:developer` 的 `log()`，应走 `LoggerService`。
///
/// `dart:developer log()` 输出到控制台但不进 LoggerService 持久化体系，
/// 日志查看器里查不到，排障时链路断裂（曾发生在 `core/update/`）。
/// 豁免:日志服务自身(`logger_service.dart` + `llm_logger/`)— 它失败时不能再调自己。
///
/// 判定:先检查文件是否 `import 'dart:developer'`（未 import 则不可能调用到它，
/// 避免误报用户自定义的 `log` 函数/方法），再匹配无接收者的顶层 `log(...)` 调用
/// （`xxx.log()` 方法调用不命中）。
class AvoidDeveloperLog extends DartLintRule {
  const AvoidDeveloperLog() : super(code: _code);

  static const _code = LintCode(
    name: 'avoid_developer_log',
    problemMessage: '禁止业务代码裸用 dart:developer 的 log(),应走 LoggerService。',
    correctionMessage:
        '用 LoggerService.instance.i/w/e(message, category: ..., tags: ...)。'
        '日志服务自身兜底用 log 除外。',
    errorSeverity: ErrorSeverity.WARNING,
  );

  @override
  void run(
    CustomLintResolver resolver,
    ErrorReporter reporter,
    CustomLintContext context,
  ) {
    if (isLoggerFile(resolver.path)) return;
    if (!_importsDartDeveloper(resolver.path)) return;
    context.registry.addMethodInvocation((node) {
      if (node.methodName.name != 'log') return;
      // 只匹配顶层函数调用（无接收者），排除 `xxx.log()` 方法/扩展调用。
      if (node.target != null) return;
      reporter.reportError(
        AnalysisError.tmp(
          source: resolver.source,
          offset: node.offset,
          length: node.length,
          errorCode: _code,
        ),
      );
    });
  }

  /// 文件是否 import 了 `dart:developer`。读不到时保守放行（回到调用检查兜底）。
  bool _importsDartDeveloper(String path) {
    try {
      return File(path).readAsStringSync().contains('dart:developer');
    } catch (_) {
      return true;
    }
  }
}
