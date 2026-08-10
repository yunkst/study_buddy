/// study_engine 数据模型。对应数据库表，不依赖 Flutter。
library;

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

/// 背诵反馈三档。
enum ReviewFeedback { forgot, remembered, easy }

/// 间隔重复调度记录。1:1 关联 topic，主键即 topic.id。
/// 懒初始化：首次背诵时才建，save_topic 不写此表。
class ReviewSchedule {
  final int topicId;
  final double easeFactor; // 难度系数，初始 2.5
  final int intervalDays; // 当前间隔天数，首学为 0
  final DateTime nextReviewAt; // 下次到期时间
  final int reviewCount; // 已复习次数
  final DateTime? lastReviewedAt; // 最近一次复习，首次为 null
  const ReviewSchedule({
    required this.topicId,
    required this.easeFactor,
    required this.intervalDays,
    required this.nextReviewAt,
    required this.reviewCount,
    this.lastReviewedAt,
  });

  factory ReviewSchedule.fromMap(Map<String, Object?> m) => ReviewSchedule(
        topicId: m['topic_id'] as int,
        easeFactor: (m['ease_factor'] as num).toDouble(),
        intervalDays: m['interval_days'] as int,
        nextReviewAt: DateTime.fromMillisecondsSinceEpoch(m['next_review_at'] as int),
        reviewCount: m['review_count'] as int,
        lastReviewedAt: m['last_reviewed_at'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(m['last_reviewed_at'] as int),
      );
  Map<String, Object?> toMap() => {
        'topic_id': topicId,
        'ease_factor': easeFactor,
        'interval_days': intervalDays,
        'next_review_at': nextReviewAt.millisecondsSinceEpoch,
        'review_count': reviewCount,
        if (lastReviewedAt != null)
          'last_reviewed_at': lastReviewedAt!.millisecondsSinceEpoch,
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
class ChatMessage {
  final String role;
  final Object content; // String 或 List<ContentPart>
  final List<ToolCall>? toolCalls;
  final String? toolCallId;
  const ChatMessage({
    required this.role,
    required this.content,
    this.toolCalls,
    this.toolCallId,
  });

  /// 序列化为 OpenAI 兼容 JSON 结构（含 vision content 数组）。
  Map<String, Object?> toJson() {
    Object jsonContent;
    if (content is String) {
      jsonContent = content as String;
    } else {
      final parts = content as List<ContentPart>;
      jsonContent = parts.map(_partToJson).toList();
    }
    final m = <String, Object?>{'role': role, 'content': jsonContent};
    if (toolCalls != null) {
      m['tool_calls'] = toolCalls!.map((t) => t.toJson()).toList();
    }
    if (toolCallId != null) m['tool_call_id'] = toolCallId;
    return m;
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

  /// 从 OpenAI 兼容 JSON 反序列化。content 可为 String 或 parts 列表。
  factory ChatMessage.fromJson(Map<String, Object?> m) {
    final rawContent = m['content'];
    Object content;
    if (rawContent is String) {
      content = rawContent;
    } else if (rawContent is List) {
      content = rawContent
          .map((e) => _partFromJson(e as Map<String, Object?>))
          .toList();
    } else {
      content = rawContent ?? '';
    }
    return ChatMessage(
      role: m['role'] as String,
      content: content,
      toolCalls: m['tool_calls'] == null
          ? null
          : (m['tool_calls'] as List)
              .map((e) => ToolCall.fromJson(e as Map<String, Object?>))
              .toList(),
      toolCallId: m['tool_call_id'] as String?,
    );
  }

  static ContentPart _partFromJson(Map<String, Object?> p) {
    switch (p['type']) {
      case 'text':
        return TextPart(p['text'] as String);
      case 'image_url':
        final img = p['image_url'] as Map<String, Object?>;
        return ImageUrlPart(img['url'] as String, detail: img['detail'] as String?);
      default:
        throw FormatException('未知 content part 类型: ${p['type']}');
    }
  }
}

/// OpenAI function calling 的工具调用。
class ToolCall {
  final String id; // 如 "call_abc"
  final String name;
  final String arguments; // 原始 JSON 字符串
  const ToolCall({required this.id, required this.name, required this.arguments});

  Map<String, Object?> toJson() => {
        'id': id,
        'type': 'function',
        'function': {'name': name, 'arguments': arguments},
      };

  factory ToolCall.fromJson(Map<String, Object?> m) {
    final fn = m['function'] as Map<String, Object?>;
    return ToolCall(
      id: m['id'] as String,
      name: fn['name'] as String,
      arguments: fn['arguments'] as String,
    );
  }
}
