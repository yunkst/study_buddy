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
  Future<void> appendMessages(int sessionId, Iterable<ChatMessage> msgs) async {
    if (msgs.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    await _db.db.transaction((txn) async {
      for (final m in msgs) {
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

  /// 按 id 升序加载某会话的全部消息（id 升序即插入时序）。
  Future<List<ChatMessage>> loadMessages(int sessionId) async {
    final rows = await _db.db.query(
      'chat_message',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'id ASC',
    );
    return rows.map(ChatMessage.fromDb).toList();
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
  Future<void> touchSession(int sessionId) async {
    await _db.db.update(
      'chat_session',
      {'updated_at': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [sessionId],
    );
  }
}

