import 'package:analyzer/error/error.dart' hide LintCode;
import 'package:analyzer/error/listener.dart';
import 'package:custom_lint_builder/custom_lint_builder.dart';

import '../path_utils.dart';

/// 禁止业务代码裸用 `debugPrint`,应走 `LoggerService`。
///
/// 日志统一入口 LoggerService(持久化 + 分级 + 分类 tag),
/// 业务裸 debugPrint 绕过持久化,排障时查不到。
/// 豁免:日志服务自身(`logger_service.dart` + `llm_logger/`)— 它失败时不能再调自己。
///
/// 注:`print` 已被 flutter_lints 的 `avoid_print` 拦截,本规则补 `debugPrint`。
class AvoidBusinessDebugPrint extends DartLintRule {
  const AvoidBusinessDebugPrint() : super(code: _code);

  static const _code = LintCode(
    name: 'avoid_business_debug_print',
    problemMessage: '禁止业务代码裸用 debugPrint,应走 LoggerService。',
    correctionMessage:
        '用 LoggerService.instance.i/w/e/d(message, category: ...)。'
        '日志服务自身兜底用 debugPrint 除外。',
    errorSeverity: ErrorSeverity.WARNING,
  );

  @override
  void run(
    CustomLintResolver resolver,
    ErrorReporter reporter,
    CustomLintContext context,
  ) {
    if (isLoggerFile(resolver.path)) return;
    context.registry.addMethodInvocation((node) {
      if (node.methodName.name != 'debugPrint') return;
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
}
