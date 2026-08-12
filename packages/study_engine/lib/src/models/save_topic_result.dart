/// 保存知识点的统一返回结果。供 AI 工具/调度入口向调用方报告:
///
/// - [id] 落库后的 row id(或已存在记录的 id)。
/// - [isNew] 是否为新建记录(true = 首次建立 Topic, false = 已存在并更新)。
/// - [message] 人类可读消息,适合直接拼接进 LLM 上下文或向用户展示。
///
/// [toJson] 输出键固定为 `id` / `is_new` / `msg`,与下游契约强相关,请勿改名。
library;

class SaveTopicResult {
  final int id;
  final bool isNew;
  final String message;

  const SaveTopicResult({
    required this.id,
    required this.isNew,
    required this.message,
  });

  Map<String, Object?> toJson() => {'id': id, 'is_new': isNew, 'msg': message};
}
