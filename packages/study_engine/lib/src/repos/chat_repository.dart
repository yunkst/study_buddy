import 'dart:convert';
import '../db/database.dart';
import '../models/models.dart';

class ChatRepository {
  final StudyDatabase _db;
  ChatRepository(this._db);

  Future<int> createSession(String scenarioId, String title, {int? topicId}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    return _db.db.insert('chat_session', {
      'scenario_id': scenarioId,
      'title': title,
      'created_at': now,
      'updated_at': now,
      if (topicId != null) 'topic_id': topicId,
    });
  }

  /// 存储消息：content 序列化为 JSON 文本（兼容纯文本与 content parts）。
  /// 注意用 toJson(forApi:false)（默认）——apiContent 注入内容永不落库，
  /// 存储保持干净原文。
  Future<int> addMessage(int sessionId, ChatMessage m) {
    return _db.db.insert('chat_message', {
      'session_id': sessionId,
      'role': m.role,
      'content': jsonEncode(m.toJson()['content']),
      'tool_calls': m.toolCalls == null
          ? null
          : jsonEncode(m.toolCalls!.map((t) => t.toJson()).toList()),
      'tool_call_id': m.toolCallId,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  /// 批量追加一轮消息（同一事务），供 AgentRoundEndEvent 的 assistant+tool 批量落库。
  /// 顺序与传入一致（id 升序即时序），保证 tool 消息紧跟带 toolCalls 的 assistant。
  /// 落库前净化：剥离 assistant 消息 tool_calls 中 id 空/args 非法的坏 ToolCall，
  /// 防止历史/外部数据绕过 agent_loop 的归一化把坏 ToolCall 落库复活。
  Future<void> appendMessages(int sessionId, Iterable<ChatMessage> msgs) async {
    if (msgs.isEmpty) return;
    final sanitized =
        msgs.map(_sanitizeForStorage).whereType<ChatMessage>().toList();
    if (sanitized.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    await _db.db.transaction((txn) async {
      for (final m in sanitized) {
        await txn.insert('chat_message', {
          'session_id': sessionId,
          'role': m.role,
          'content': jsonEncode(m.toJson()['content']),
          'tool_calls': m.toolCalls == null
              ? null
              : jsonEncode(m.toolCalls!.map((t) => t.toJson()).toList()),
          'tool_call_id': m.toolCallId,
          'created_at': now,
        });
      }
    });
  }

  /// 落库前净化：剥离坏 ToolCall；整个 assistant 的 tool_calls 全坏则丢弃该消息。
  ChatMessage? _sanitizeForStorage(ChatMessage m) {
    if (m.toolCalls == null) return m;
    final clean = m.toolCalls!.where(_isValidToolCallForStorage).toList();
    if (clean.length == m.toolCalls!.length) return m;
    if (clean.isEmpty) return null;
    return ChatMessage(
      role: m.role,
      content: m.content,
      toolCalls: clean,
      apiContent: m.apiContent,
    );
  }

  /// ToolCall 是否值得落库：id/name 非空，arguments 是可解析的 JSON 对象。
  static bool _isValidToolCallForStorage(ToolCall t) {
    if (t.id.isEmpty || t.name.isEmpty) return false;
    final trimmed = t.arguments.trim();
    if (trimmed.isEmpty) return false;
    try {
      return jsonDecode(trimmed) is Map;
    } catch (_) {
      return false;
    }
  }

  /// 按 id 升序加载某会话的全部消息（id 升序即插入时序）。
  /// 走 [ChatMessage.fromDbSanitized]：加载时自动修复历史脏数据
  /// （坏 ToolCall 剥离 + tool_call_id 空值补 session-stable 占位）。
  Future<List<ChatMessage>> loadMessages(int sessionId) async {
    final rows = await _db.db.query(
      'chat_message',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'id ASC',
    );
    // session-stable 占位 id 生成器：同一辅助逻辑内每次加载递增。
    // 注意：assistant 与其多条 tool 消息间通过「role 连续配对」保持 toolCallId
    // 与 toolCalls[].id 一致——占位 id 生成只补齐空值，不改变已配对 id。
    var recoveredN = 0;
    String nextId() => 'call_recovered_${recoveredN++}';
    return rows
        .map((r) => ChatMessage.fromDbSanitized(r, idGenerator: nextId))
        .toList();
  }

  /// 最近更新的某场景会话（用于 App 重启续聊）。无则返回 null。
  ///
  /// [mainlineOnly] 为 true（默认）时只取 topic_id IS NULL 的主线会话，
  /// 避免把知识点教学会话误当主线恢复；false 时取任意会话。
  Future<ChatSession?> latestSession(String scenarioId,
      {bool mainlineOnly = true}) async {
    final rows = await _db.db.query(
      'chat_session',
      where: mainlineOnly
          ? 'scenario_id = ? AND topic_id IS NULL'
          : 'scenario_id = ?',
      whereArgs: [scenarioId],
      orderBy: 'updated_at DESC, id DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return ChatSession.fromMap(rows.first);
  }

  /// 某知识点的专属教学会话（scenario_id='study_plan' 且 topic_id=?）。
  /// 命中即复用（每 topic 至多一条），未命中返回 null。
  Future<ChatSession?> findTeachingSession(int topicId) async {
    final rows = await _db.db.query(
      'chat_session',
      where: 'scenario_id = ? AND topic_id = ?',
      whereArgs: ['study_plan', topicId],
      orderBy: 'updated_at DESC, id DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return ChatSession.fromMap(rows.first);
  }

  /// 更新会话 updated_at（每轮持久化后调用，保证「最近会话」排序准确）。
  /// [at] 可选显式时间戳（测试注入确定时钟）；缺省用当前时间。
  Future<void> touchSession(int sessionId, {DateTime? at}) async {
    await _db.db.update(
      'chat_session',
      {'updated_at': (at ?? DateTime.now()).millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [sessionId],
    );
  }
}

