import 'dart:convert';
import '../db/database.dart';
import '../models/models.dart';

class ChatRepository {
  final StudyDatabase _db;
  ChatRepository(this._db);

  /// 创建会话。topicId 可空(向后兼容)。
  Future<int> createSession(String scenarioId, String title, {int? topicId}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    return _db.db.insert('chat_session', {
      'scenario_id': scenarioId,
      'title': title,
      if (topicId != null) 'topic_id': topicId,
      'created_at': now,
      'updated_at': now,
    });
  }

  /// 按知识点查会话,无则创建。利用 UNIQUE(topic_id) 原子语义。
  Future<int> findOrCreateByTopic(int topicId, String title) async {
    final rows = await _db.db.query('chat_session',
        where: 'topic_id = ?', whereArgs: [topicId], limit: 1);
    if (rows.isNotEmpty) return rows.first['id'] as int;
    try {
      return await createSession('study', title, topicId: topicId);
    } catch (e) {
      // 并发下另一会话已建同 topic_id → UNIQUE 冲突 → 再查一次
      if (e.toString().contains('UNIQUE constraint failed')) {
        final r = await _db.db.query('chat_session',
            where: 'topic_id = ?', whereArgs: [topicId], limit: 1);
        if (r.isNotEmpty) return r.first['id'] as int;
      }
      rethrow;
    }
  }

  /// 读某会话全部消息,按 created_at 正序,反序列化回 ChatMessage。
  Future<List<ChatMessage>> listMessages(int sessionId) async {
    final rows = await _db.db.query('chat_message',
        where: 'session_id = ?', whereArgs: [sessionId],
        orderBy: 'created_at ASC, id ASC');
    return rows.map((r) {
      final contentJson = jsonDecode(r['content'] as String);
      final toolCallsJson = r['tool_calls'] == null
          ? null
          : jsonDecode(r['tool_calls'] as String) as List;
      return ChatMessage.fromJson({
        'role': r['role'],
        'content': contentJson,
        if (toolCallsJson != null) 'tool_calls': toolCallsJson,
        if (r['tool_call_id'] != null) 'tool_call_id': r['tool_call_id'],
      });
    }).toList();
  }

  /// 存储消息：content 序列化为 JSON 文本（兼容纯文本与 content parts）。
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
}
