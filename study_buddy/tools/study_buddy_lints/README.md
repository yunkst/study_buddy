# study_buddy_lints

Study Buddy 自定义 lint 规则（`custom_lint`）—— 主题约束 + 日志约束。

## 规则

| 规则 | 约束 | 豁免 |
|---|---|---|
| `avoid_literal_color` | 禁硬编码 `Color(0x...)` 字面量（含 `fromARGB`/`fromRGBO`） | `lib/core/theme/`（主题定义处） |
| `avoid_material_colors` | 禁 `Colors.*` Material 固定色（`Colors.transparent` 放行） | `lib/core/theme/` |
| `avoid_literal_font_family` | 禁裸写 `fontFamily: '...'` 字面量 | `lib/core/theme/`（字体定义处） |
| `avoid_business_debug_print` | 禁业务代码裸用 `debugPrint`（应走 `LoggerService`） | `logger_service.dart` + `llm_logger/`（日志自身兜底） |

所有规则默认 **WARNING**：存量违规不阻断 CI（退出码 0），但 IDE 实时提示新违规。
存量清零后可在 CI 加 `--fatal-warnings` 收紧为门禁。

## 启用（已在 study_buddy 接入）

- `study_buddy/analysis_options.yaml`：`analyzer.plugins: [custom_lint]`
- `study_buddy/pubspec.yaml` dev_dependencies：`custom_lint` + `study_buddy_lints`（path）

## 运行

| 场景 | 方式 |
|---|---|
| IDE（VS Code / Android Studio） | analysis server 自动加载，实时提示 |
| CLI / CI | `dart run custom_lint`（CI 的 `flutter-ci.yml` 已加） |
| `flutter analyze` | **不加载 analyzer plugins**（custom_lint 架构限制，见下） |

## 架构注意

- `flutter analyze` CLI **不运行** custom_lint 规则——analyzer plugins 只在 IDE 的
  analysis server 中加载。CI 强制检查必须用独立的 `dart run custom_lint` 步骤。
- **版本约束**：`custom_lint_builder` 0.7.x 的 `custom_lint_visitor` 要求
  `analyzer <7.7.0`（无 7.7 档）。规则包因此锁 `analyzer 7.6.0`，与 Flutter
  主 analyzer 7.7.1 的小版本差由 custom_lint 独立进程兼容。升级 Flutter 时
  若 analyzer 大版本跳变，需同步升级 custom_lint 并核对本约束。

## 新增规则

```dart
class MyRule extends DartLintRule {
  const MyRule() : super(code: _code);
  static const _code = LintCode(
    name: 'my_rule',
    problemMessage: '...',
    correctionMessage: '...',
    errorSeverity: ErrorSeverity.WARNING,
  );
  @override
  void run(CustomLintResolver resolver, ErrorReporter reporter, CustomLintContext context) {
    context.registry.addInstanceCreationExpression((node) {
      reporter.reportError(AnalysisError.tmp(
        source: resolver.source,
        offset: node.offset,
        length: node.length,
        errorCode: _code,
      ));
    });
  }
}
```

在 `lib/study_buddy_lints.dart` 的 `getLintRules` 注册。
