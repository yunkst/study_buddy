// Study Buddy 自定义 lint 插件入口。
//
// custom_lint 通过约定查找本包顶层 `createPlugin()` 函数加载规则。
// 应用侧在 analysis_options.yaml 写 `analyzer.plugins: [custom_lint]` 并
// dev_dependencies 依赖本包即可启用。

import 'package:custom_lint_builder/custom_lint_builder.dart';

import 'src/rules/avoid_business_debug_print.dart';
import 'src/rules/avoid_developer_log.dart';
import 'src/rules/avoid_literal_color.dart';
import 'src/rules/avoid_literal_font_family.dart';
import 'src/rules/avoid_material_colors.dart';

PluginBase createPlugin() => _StudyBuddyLintsPlugin();

class _StudyBuddyLintsPlugin extends PluginBase {
  @override
  List<LintRule> getLintRules(CustomLintConfigs configs) => [
        const AvoidLiteralColor(),
        const AvoidMaterialColors(),
        const AvoidLiteralFontFamily(),
        const AvoidBusinessDebugPrint(),
        const AvoidDeveloperLog(),
      ];
}
