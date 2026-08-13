import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/error/error.dart' hide LintCode;
import 'package:analyzer/error/listener.dart';
import 'package:custom_lint_builder/custom_lint_builder.dart';

import '../path_utils.dart';

/// 禁止业务代码裸写 `fontFamily: 'xxx'`,应走 `textTheme`。
///
/// 命中条件:`TextStyle(fontFamily: '字面量')` 或 `copyWith(fontFamily: '字面量')`。
/// 豁免:`lib/core/theme/`(字体定义处)。
class AvoidLiteralFontFamily extends DartLintRule {
  const AvoidLiteralFontFamily() : super(code: _code);

  static const _code = LintCode(
    name: 'avoid_literal_font_family',
    problemMessage: '禁止裸写 fontFamily 字面量,应走 textTheme。',
    correctionMessage: '用 Theme.of(context).textTheme.xxx。'
        '新字体族请加到 lib/core/theme/app_typography.dart。',
    errorSeverity: ErrorSeverity.WARNING,
  );

  @override
  void run(
    CustomLintResolver resolver,
    ErrorReporter reporter,
    CustomLintContext context,
  ) {
    if (isExemptFile(resolver.path)) return;
    context.registry.addNamedExpression((node) {
      if (node.name.label.name != 'fontFamily') return;
      final lit = node.expression;
      if (lit is! StringLiteral) return;
      // monospace:等宽字体是日志/代码/堆栈渲染的固有语义,textTheme 无等宽角色,放行。
      if (lit.stringValue == 'monospace') return;
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
