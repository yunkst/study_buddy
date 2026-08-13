/// ask_user 工具的数据模型（引擎层纯 Dart，不依赖 Flutter）。
///
/// LLM 调用 ask_user 时，引擎把解析出的问题包装成 [AskUserRequest] 通过
/// [AskUserRequestedEvent] 发给 UI；UI 渲染选项卡片，用户作答后经
/// [completeAskUser] 把答案回灌，作为 ask_user 工具的结果字符串返回给 LLM。
library;

/// 单个选项。
class AskUserOption {
  final String label;
  final String value;
  final String? description;
  const AskUserOption({
    required this.label,
    required this.value,
    this.description,
  });
}

/// LLM 通过 ask_user 提出的一个结构化提问。
class AskUserRequest {
  /// 给用户看的提问文案。
  final String question;

  /// 卡片左上角小标题（可省）。
  final String? header;

  /// 选项列表。为空表示退化为“必答自由输入”。
  final List<AskUserOption> options;

  /// 是否允许多选。多选时 result 为选中的 value 用 `', '` 拼接。
  final bool multiSelect;

  /// 是否必答。当前固定 true，预留未来“可跳过”能力。
  final bool required;

  /// 对应工具调用的 id（与 ToolCallStartEvent.toolCallId 一致）。
  final String toolCallId;

  const AskUserRequest({
    required this.question,
    required this.options,
    required this.toolCallId,
    this.header,
    this.multiSelect = false,
    this.required = true,
  });

  /// 无选项 = 自由输入模式。
  bool get isFreeInput => options.isEmpty;
}