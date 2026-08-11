import 'dart:convert';
import '../db/database.dart';
import '../models/models.dart';

class ChatRepository {
  final StudyDatabase _db;
  ChatRepository(this._db);

  Future<int> createSession(String scenarioId, String title) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    return _db.db.insert('chat_session', {
      'scenario_id': scenarioId,
      'title': title,
      'created_at': now,
      'updated_at': now,
    });
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
