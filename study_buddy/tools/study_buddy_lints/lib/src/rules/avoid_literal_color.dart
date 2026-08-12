import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/error/error.dart' hide LintCode;
import 'package:analyzer/error/listener.dart';
import 'package:custom_lint_builder/custom_lint_builder.dart';

import '../path_utils.dart';

/// 禁止硬编码 `Color(0x...)` / `Color.fromARGB(...)` / `Color.fromRGBO(...)` 字面量。
///
/// 命中条件:Color 构造且实参含整数字面量(`Color(someVar)` 不拦,已是 token 引用)。
/// 豁免:`lib/core/theme/`(主题定义处)。
///
/// 新增主题色请走 `app_colors.dart` / `paper_extension.dart`,业务代码用
/// `Theme.of(context).colorScheme.xxx` 或 `theme.extension<PaperColors>()!.xxx`。
class AvoidLiteralColor extends DartLintRule {
  const AvoidLiteralColor() : super(code: _code);

  static const _code = LintCode(
    name: 'avoid_literal_color',
    problemMessage: '禁止硬编码 Color 字面量,应走主题 token。',
    correctionMessage:
        '用 Theme.of(context).colorScheme.xxx 或 theme.extension<PaperColors>()!.xxx。'
        '新色值请加到 lib/core/theme/。',
    errorSeverity: ErrorSeverity.WARNING,
  );

  @override
  void run(
    CustomLintResolver resolver,
    ErrorReporter reporter,
    CustomLintContext context,
  ) {
    if (isThemeFile(resolver.path)) return;
    context.registry.addInstanceCreationExpression((node) {
      final name = node.constructorName.type.name2.lexeme;
      if (name != 'Color') return;
      final isLiteral =
          node.argumentList.arguments.any((a) => a is IntegerLiteral);
      if (!isLiteral) return;
      _report(reporter, resolver, node);
    });
  }

  void _report(
    ErrorReporter reporter,
    CustomLintResolver resolver,
    AstNode node,
  ) {
    reporter.reportError(
      AnalysisError.tmp(
        source: resolver.source,
        offset: node.offset,
        length: node.length,
        errorCode: _code,
      ),
    );
  }
}
