import 'package:analyzer/error/error.dart' hide LintCode;
import 'package:analyzer/error/listener.dart';
import 'package:custom_lint_builder/custom_lint_builder.dart';

import '../path_utils.dart';

/// 禁止 `Colors.*`(Material 固定色),逼业务代码走主题 ColorScheme。
///
/// 状态语义色(完成绿/逾期红)应抽象为主题 token,而非散落 `Colors.green`。
/// 豁免:`lib/core/theme/`;`Colors.transparent`(透明无主题含义,合理)放行。
class AvoidMaterialColors extends DartLintRule {
  const AvoidMaterialColors() : super(code: _code);

  static const _code = LintCode(
    name: 'avoid_material_colors',
    problemMessage: '禁止 Colors.* 固定色,应走主题 colorScheme。',
    correctionMessage: '用 Theme.of(context).colorScheme.xxx。'
        '状态色(成功/危险)请抽象为主题 token。',
    errorSeverity: ErrorSeverity.WARNING,
  );

  @override
  void run(
    CustomLintResolver resolver,
    ErrorReporter reporter,
    CustomLintContext context,
  ) {
    if (isThemeFile(resolver.path)) return;
    context.registry.addPrefixedIdentifier((node) {
      if (node.prefix.name != 'Colors') return;
      // transparent 无主题含义(纯透明),放行。
      if (node.identifier.name == 'transparent') return;
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
