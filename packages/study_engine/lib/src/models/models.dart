/// study_engine 数据模型。对应数据库表，不依赖 Flutter。
library;

import 'dart:convert';

export 'plan_models.dart';
export 'rating.dart';
export 'save_topic_result.dart';
export 'topic_schedule.dart';

/// 分类节点。自引用树，承载 学科→模块→章节。学科是顶级节点（parent_id 为 null）。
class Category {
  final int? id;
  final int? parentId;
  final String name;
  final int sortOrder;
  final DateTime createdAt;
  const Category({
    this.id,
    this.parentId,
    required this.name,
    this.sortOrder = 0,
    required this.createdAt,
  });

  factory Category.fromMap(Map<String, Object?> m) => Category(
        id: m['id'] as int?,
        parentId: m['parent_id'] as int?,
        name: m['name'] as String,
        sortOrder: (m['sort_order'] as int?) ?? 0,
        createdAt: DateTime.fromMillisecondsSinceEpoch(m['created_at'] as int),
      );
  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        if (parentId != null) 'parent_id': parentId,
        'name': name,
        'sort_order': sortOrder,
        'created_at': createdAt.millisecondsSinceEpoch,
      };
}

/// 知识点。挂载到 Category，含背诵引子(question)与答案本体(summary)。
class Topic {
  final int? id;
  final int categoryId;
  final String question; // 必填：背诵引子
  final String title; // 全库唯一
  final String summary; // 必填：答案本体，背诵揭晓内容
  final DateTime createdAt;
  final DateTime updatedAt;
  const Topic({
    this.id,
    required this.categoryId,
    required this.question,
    required this.title,
    required this.summary,
    required this.createdAt,
    required this.updatedAt,
  });

  factory Topic.fromMap(Map<String, Object?> m) => Topic(
        id: m['id'] as int?,
        categoryId: m['category_id'] as int,
        question: m['question'] as String,
        title: m['title'] as String,
        summary: m['summary'] as String,
        createdAt: DateTime.fromMillisecondsSinceEpoch(m['created_at'] as int),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(m['updated_at'] as int),
      );
  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'category_id': categoryId,
        'question': question,
        'title': title,
        'summary': summary,
        'created_at': createdAt.millisecondsSinceEpoch,
        'updated_at': updatedAt.millisecondsSinceEpoch,
      };
}

/// 知识点关联边。prerequisite=前置依赖(有向)，related=相关(无向)。
class TopicEdge {
  final int? id;
  final int fromTopicId;
  final int toTopicId;
  final String type; // 'prerequisite' | 'related'
  final DateTime createdAt;
  const TopicEdge({
    this.id,
    required this.fromTopicId,
    required this.toTopicId,
    required this.type,
    required this.createdAt,
  });

  factory TopicEdge.fromMap(Map<String, Object?> m) => TopicEdge(
        id: m['id'] as int?,
        fromTopicId: m['from_topic_id'] as int,
        toTopicId: m['to_topic_id'] as int,
        type: m['type'] as String,
        createdAt: DateTime.fromMillisecondsSinceEpoch(m['created_at'] as int),
      );
  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'from_topic_id': fromTopicId,
        'to_topic_id': toTopicId,
        'type': type,
        'created_at': createdAt.millisecondsSinceEpoch,
      };
}

/// 掌握状态枚举。
enum MasteryStatus { unknown, learning, mastered, weak }

extension MasteryStatusX on MasteryStatus {
  String get wire => name;
  static MasteryStatus fromWire(String s) =>
      MasteryStatus.values.firstWhere((e) => e.name == s, orElse: () => MasteryStatus.unknown);
}

/// 掌握状态变更日志。
class MasteryLog {
  final int? id;
  final int topicId;
  final MasteryStatus status;
  final String? reason;
  final DateTime changedAt;
  const MasteryLog({
    this.id,
    required this.topicId,
    required this.status,
    this.reason,
    required this.changedAt,
  });

  factory MasteryLog.fromMap(Map<String, Object?> m) => MasteryLog(
        id: m['id'] as int?,
        topicId: m['topic_id'] as int,
        status: MasteryStatusX.fromWire(m['status'] as String),
        reason: m['reason'] as String?,
        changedAt: DateTime.fromMillisecondsSinceEpoch(m['changed_at'] as int),
      );
  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'topic_id': topicId,
        'status': status.wire,
        if (reason != null) 'reason': reason,
        'changed_at': changedAt.millisecondsSinceEpoch,
      };
}

/// LLM 供应商配置。
class LlmConfig {
  final int? id;
  final String name;
  final String apiUrl;
  final String apiKey;
  final String model;
  final bool supportsVision;
  final bool isDefault;
  final int sortOrder;
  final DateTime createdAt;
  const LlmConfig({
    this.id,
    required this.name,
    required this.apiUrl,
    required this.apiKey,
    required this.model,
    this.supportsVision = false,
    this.isDefault = false,
    this.sortOrder = 0,
    required this.createdAt,
  });

  factory LlmConfig.fromMap(Map<String, Object?> m) => LlmConfig(
        id: m['id'] as int?,
        name: m['name'] as String,
        apiUrl: m['api_url'] as String,
        apiKey: m['api_key'] as String,
        model: m['model'] as String,
        supportsVision: (m['supports_vision'] as int) == 1,
        isDefault: (m['is_default'] as int) == 1,
        sortOrder: m['sort_order'] as int,
        createdAt: DateTime.fromMillisecondsSinceEpoch(m['created_at'] as int),
      );
  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'name': name,
        'api_url': apiUrl,
        'api_key': apiKey,
        'model': model,
        'supports_vision': supportsVision ? 1 : 0,
        'is_default': isDefault ? 1 : 0,
        'sort_order': sortOrder,
        'created_at': createdAt.millisecondsSinceEpoch,
      };
  LlmConfig copyWith({
    int? id,
    String? name,
    String? apiUrl,
    String? apiKey,
    String? model,
    bool? supportsVision,
    bool? isDefault,
    int? sortOrder,
    DateTime? createdAt,
  }) {
    return LlmConfig(
      id: id ?? this.id,
      name: name ?? this.name,
      apiUrl: apiUrl ?? this.apiUrl,
      apiKey: apiKey ?? this.apiKey,
      model: model ?? this.model,
      supportsVision: supportsVision ?? this.supportsVision,
      isDefault: isDefault ?? this.isDefault,
      sortOrder: sortOrder ?? this.sortOrder,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}

/// agent 经验记忆。
class AgentMemory {
  final int? id;
  final String scenarioId;
  final String content;
  final DateTime createdAt;
  const AgentMemory({this.id, required this.scenarioId, required this.content, required this.createdAt});

  factory AgentMemory.fromMap(Map<String, Object?> m) => AgentMemory(
        id: m['id'] as int?,
        scenarioId: m['scenario_id'] as String,
        content: m['content'] as String,
        createdAt: DateTime.fromMillisecondsSinceEpoch(m['created_at'] as int),
      );
  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'scenario_id': scenarioId,
        'content': content,
        'created_at': createdAt.millisecondsSinceEpoch,
      };
}

/// 对话会话。
class ChatSession {
  final int? id;
  final String scenarioId;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;
  const ChatSession({
    this.id,
    required this.scenarioId,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
  });

  factory ChatSession.fromMap(Map<String, Object?> m) => ChatSession(
        id: m['id'] as int?,
        scenarioId: m['scenario_id'] as String,
        title: m['title'] as String,
        createdAt: DateTime.fromMillisecondsSinceEpoch(m['created_at'] as int),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(m['updated_at'] as int),
      );
  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'scenario_id': scenarioId,
        'title': title,
        'created_at': createdAt.millisecondsSinceEpoch,
        'updated_at': updatedAt.millisecondsSinceEpoch,
      };
}

// ===== vision content parts =====

/// ChatMessage content 的一个片段。sealed，仅 TextPart / ImageUrlPart。
sealed class ContentPart {
  const ContentPart();
}

class TextPart extends ContentPart {
  final String text;
  const TextPart(this.text);
}

class ImageUrlPart extends ContentPart {
  final String url; // base64 data URI 或 http URL
  final String? detail; // low / high / auto
  const ImageUrlPart(this.url, {this.detail});
}

/// 对话消息。content 既可纯文本，也可为 ContentPart 列表（vision）。
///
/// [apiContent] 是「发送给 LLM 的旁车内容」（hermes api_content 思路）：
/// 非空时，发给 LLM 用 [apiContent]，而存储/UI 用 [content]。用于把记忆、
/// 插件上下文等瞬时注入拼到当前轮用户消息上，同时保持持久化内容干净。
/// apiContent 只存在内存里（由 AgentLoop 每轮现场 stamp），永不落库。
class ChatMessage {
  final String role;
  final Object content; // String 或 List<ContentPart>
  final String? apiContent; // 非空时发给 LLM 用这份，存储/UI 仍用 content
  final List<ToolCall>? toolCalls;
  final String? toolCallId;
  const ChatMessage({
    required this.role,
    required this.content,
    this.apiContent,
    this.toolCalls,
    this.toolCallId,
  });

  /// 序列化为 OpenAI 兼容 JSON 结构（含 vision content 数组）。
  ///
  /// [forApi] 为 true 时表示发给 LLM：content 字段优先取 [apiContent]（无则回退 content）。
  /// 默认（forApi=false，即存储/日志路径）始终用 [content]，不写 apiContent——
  /// 保证落库与 UI 显示的永远是干净原文，注入内容只出现在发给模型的那一份。
  ///
  /// 空内容归一化：当 [forApi] 为 true 且 content 解析后为空字符串时，输出 `null`。
  /// 这是为了兼容 k3 等非标准端点——它们拒绝带 `content:""` 的 assistant 消息
  /// （常见于「只调用工具、没有文本」的轮次），返回 400 `text content is empty`。
  /// 协议本身允许 `content:null`，故这是更安全的发送形态。存储/UI 路径（forApi=false）
  /// 不受影响，仍如实保留空串。详见 test/models_test.dart 的「空内容 forApi」用例。
  Map<String, Object?> toJson({bool forApi = false}) {
    final api = forApi ? apiContent : null;
    Object? jsonContent;
    if (api != null) {
      jsonContent = api;
    } else if (content is String) {
      jsonContent = content as String;
    } else {
      final parts = content as List<ContentPart>;
      jsonContent = parts.map(_partToJson).toList();
    }
    if (forApi && jsonContent == '') jsonContent = null;
    final m = <String, Object?>{'role': role, 'content': jsonContent};
    if (toolCalls != null) {
      m['tool_calls'] = toolCalls!.map((t) => t.toJson()).toList();
    }
    if (toolCallId != null && toolCallId!.isNotEmpty) m['tool_call_id'] = toolCallId;
    return m;
  }

  /// 从 OpenAI 兼容 JSON 结构反序列化（toJson(forApi:false) 的逆过程）。
  /// content 字段支持 String（纯文本）或 List（vision parts）。
  /// [apiContent] 不参与序列化，重建时为 null——它是内存瞬时态。
  factory ChatMessage.fromJson(Map<String, Object?> json) {
    final role = json['role'] as String;
    final content = _contentFromJson(json['content']);
    final toolCallsRaw = json['tool_calls'] as List?;
    final toolCalls = toolCallsRaw
        ?.map((e) => _toolCallFromJson(e as Map<String, Object?>))
        .toList();
    return ChatMessage(
      role: role,
      content: content,
      toolCalls: toolCalls,
      toolCallId: json['tool_call_id'] as String?,
    );
  }

  /// 从 chat_message 表行反序列化。content/tool_calls 列存的是 JSON 文本
  /// （addMessage 时 jsonEncode 的结果），需各自 jsonDecode 一层。
  factory ChatMessage.fromDb(Map<String, Object?> row) {
    final contentRaw = row['content'] as String;
    final content = _contentFromJson(jsonDecode(contentRaw));
    final toolCallsRaw = row['tool_calls'] as String?;
    final toolCalls = toolCallsRaw == null
        ? null
        : (jsonDecode(toolCallsRaw) as List)
            .map((e) => _toolCallFromJson(e as Map<String, Object?>))
            .toList();
    return ChatMessage(
      role: row['role'] as String,
      content: content,
      toolCalls: toolCalls,
      toolCallId: () {
        final v = row['tool_call_id'] as String?;
        return v == null || v.isEmpty ? null : v;
      }(),
    );
  }

  /// content 的 JSON 值 → 引擎对象（String 或 ContentPart 列表）。
  static Object _contentFromJson(Object? raw) {
    if (raw is String) return raw;
    if (raw is List) {
      return raw.map((e) => _partFromJson(e as Map<String, Object?>)).toList();
    }
    return '';
  }

  static ContentPart _partFromJson(Map<String, Object?> j) {
    switch (j['type']) {
      case 'text':
        return TextPart(j['text'] as String? ?? '');
      case 'image_url':
        final img = j['image_url'] as Map<String, Object?>?;
        return ImageUrlPart(
          img?['url'] as String? ?? '',
          detail: img?['detail'] as String?,
        );
      default:
        throw FormatException('未知 content part type: ${j['type']}');
    }
  }

  static ToolCall _toolCallFromJson(Map<String, Object?> j) {
    final fn = j['function'] as Map<String, Object?>? ?? const {};
    return ToolCall(
      id: j['id'] as String? ?? 'call_unknown',
      name: fn['name'] as String? ?? '',
      arguments: fn['arguments'] as String? ?? '',
    );
  }

  static Map<String, Object?> _partToJson(ContentPart p) {
    switch (p) {
      case TextPart(:final text):
        return {'type': 'text', 'text': text};
      case ImageUrlPart(:final url, :final detail):
        final img = <String, Object?>{'url': url};
        if (detail != null) img['detail'] = detail;
        return {'type': 'image_url', 'image_url': img};
    }
  }
}

/// OpenAI function calling 的工具调用。
class ToolCall {
  final String id; // 如 "call_abc"
  final String name;
  final String arguments; // 原始 JSON 字符串
  const ToolCall({required this.id, required this.name, required this.arguments});

  ToolCall copyWith({String? id, String? name, String? arguments}) => ToolCall(
        id: id ?? this.id,
        name: name ?? this.name,
        arguments: arguments ?? this.arguments,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'type': 'function',
        'function': {'name': name, 'arguments': arguments},
      };
}

/// 批改明细中单题的结构。
class ReviewItem {
  final int seq;
  final String question;
  final String? userAnswer;
  final String verdict; // correct | partial | wrong
  final String analysis;
  final List<int> topicIds;
  const ReviewItem({
    required this.seq,
    required this.question,
    this.userAnswer,
    required this.verdict,
    required this.analysis,
    this.topicIds = const [],
  });

  Map<String, Object?> toJson() => {
        'seq': seq,
        'question': question,
        if (userAnswer != null) 'user_answer': userAnswer,
        'verdict': verdict,
        'analysis': analysis,
        'topic_ids': topicIds,
      };

  factory ReviewItem.fromJson(Map<String, Object?> j) => ReviewItem(
        seq: j['seq'] as int,
        question: j['question'] as String,
        userAnswer: j['user_answer'] as String?,
        verdict: j['verdict'] as String,
        analysis: j['analysis'] as String,
        topicIds: (j['topic_ids'] as List).map((e) => e as int).toList(),
      );
}

/// 一次批改记录(对应 review 表一行,items 反序列化为 ReviewItem 列表)。
class Review {
  final int? id;
  final int? chatSessionId;
  final String summary;
  final List<ReviewItem> items;
  final DateTime createdAt;
  const Review({
    this.id,
    this.chatSessionId,
    required this.summary,
    required this.items,
    required this.createdAt,
  });

  factory Review.fromMap(Map<String, Object?> m) {
    final itemsRaw = jsonDecode(m['items'] as String) as List;
    return Review(
      id: m['id'] as int?,
      chatSessionId: m['chat_session_id'] as int?,
      summary: m['summary'] as String,
      items: itemsRaw.map((e) => ReviewItem.fromJson(e as Map<String, Object?>)).toList(),
      createdAt: DateTime.fromMillisecondsSinceEpoch(m['created_at'] as int),
    );
  }
}

/// 一次专注学习会话。endedAt/durationMs 为 null 表示进行中。
/// summary 为用户停止时输入的「这段时间做了什么」备注，可空。
class FocusSession {
  final int? id;
  final DateTime startedAt;
  final DateTime? endedAt;
  final int? durationMs;
  final String? summary;
  const FocusSession({
    this.id,
    required this.startedAt,
    this.endedAt,
    this.durationMs,
    this.summary,
  });

  factory FocusSession.fromMap(Map<String, Object?> m) => FocusSession(
        id: m['id'] as int?,
        startedAt: DateTime.fromMillisecondsSinceEpoch(m['started_at'] as int),
        endedAt: m['ended_at'] != null
            ? DateTime.fromMillisecondsSinceEpoch(m['ended_at'] as int)
            : null,
        durationMs: m['duration_ms'] as int?,
        summary: m['summary'] as String?,
      );
  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'started_at': startedAt.millisecondsSinceEpoch,
        if (endedAt != null) 'ended_at': endedAt!.millisecondsSinceEpoch,
        if (durationMs != null) 'duration_ms': durationMs,
        if (summary != null) 'summary': summary,
      };
}

/// 专注会话与知识点的关联（多对多，不记时长）。UNIQUE(session_id, topic_id)。
class FocusSessionTopic {
  final int? id;
  final int sessionId;
  final int topicId;
  final DateTime linkedAt;
  const FocusSessionTopic({
    this.id,
    required this.sessionId,
    required this.topicId,
    required this.linkedAt,
  });

  factory FocusSessionTopic.fromMap(Map<String, Object?> m) => FocusSessionTopic(
        id: m['id'] as int?,
        sessionId: m['session_id'] as int,
        topicId: m['topic_id'] as int,
        linkedAt: DateTime.fromMillisecondsSinceEpoch(m['linked_at'] as int),
      );
  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'session_id': sessionId,
        'topic_id': topicId,
        'linked_at': linkedAt.millisecondsSinceEpoch,
      };
}
