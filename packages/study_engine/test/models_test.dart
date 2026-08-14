import 'package:test/test.dart';
import 'package:study_engine/study_engine.dart';

void main() {
  test('纯文本 ChatMessage 序列化为字符串 content', () {
    final m = const ChatMessage(role: 'user', content: '你好');
    expect(m.toJson(), {'role': 'user', 'content': '你好'});
  });

  test('仅工具调用的空内容 assistant：forApi 归一化为 null，存储路径保留空串', () {
    final m = ChatMessage(
      role: 'assistant',
      content: '',
      toolCalls: [const ToolCall(id: 'call_1', name: 'list_topics', arguments: '{}')],
    );
    // 发给 LLM：空 content → null（k3 等端点拒绝 content:""，见 400 text content is empty）
    final api = m.toJson(forApi: true);
    expect(api['content'], isNull);
    expect(api['role'], 'assistant');
    expect((api['tool_calls'] as List).first['function']['name'], 'list_topics');
    // 存储/UI 路径不受影响：仍如实写空串，保证 fromJson 往返稳定
    expect(m.toJson(), {'role': 'assistant', 'content': '', 'tool_calls': isNotNull});
  });

  test('forApi 下非空文本不受空内容归一化影响', () {
    final m = const ChatMessage(role: 'assistant', content: '好的，我来查一下');
    expect(m.toJson(forApi: true)['content'], '好的，我来查一下');
  });

  test('vision ChatMessage 序列化为 content parts 数组', () {
    final m = ChatMessage(
      role: 'user',
      content: const [
        TextPart('分析这道题'),
        ImageUrlPart('data:image/jpeg;base64,AAAA'),
      ],
    );
    final json = m.toJson();
    expect(json['role'], 'user');
    final content = json['content'] as List;
    expect(content.first, {'type': 'text', 'text': '分析这道题'});
    expect(content.last, {
      'type': 'image_url',
      'image_url': {'url': 'data:image/jpeg;base64,AAAA'},
    });
  });

  test('toolCallId 为空串时 forApi 不写出 tool_call_id 字段', () {
    // 防御 400 tool_call_id  is not found：空串 id 不应发给 LLM
    final m = ChatMessage(role: 'tool', content: '结果', toolCallId: '');
    final api = m.toJson(forApi: true);
    expect(api.containsKey('tool_call_id'), isFalse,
        reason: '空串 toolCallId 不应序列化，否则网关报 400');
    expect(api['role'], 'tool');
    // 非空 toolCallId 仍然正常写出
    final m2 = ChatMessage(role: 'tool', content: '结果', toolCallId: 'call_1');
    expect(m2.toJson(forApi: true)['tool_call_id'], 'call_1');
  });

  test('fromDb 中空串 tool_call_id 归一化为 null', () {
    // 历史数据中可能存了空串，读出来应转成 null
    final row = {
      'id': 1,
      'chat_id': 1,
      'role': 'tool',
      'content': '"结果"',
      'tool_calls': null,
      'tool_call_id': '',
      'api_content': null,
      'created_at': 0,
    };
    final m = ChatMessage.fromDb(row);
    expect(m.toolCallId, isNull, reason: '空串 tool_call_id 应归一化为 null');
    // 正常非空 id 不受影响
    final row2 = {
      'id': 2,
      'chat_id': 1,
      'role': 'tool',
      'content': '"结果"',
      'tool_calls': null,
      'tool_call_id': 'call_abc',
      'api_content': null,
      'created_at': 0,
    };
    expect(ChatMessage.fromDb(row2).toolCallId, 'call_abc');
    // NULL 值也正常为 null
    final row3 = {
      'id': 3,
      'chat_id': 1,
      'role': 'user',
      'content': '"hi"',
      'tool_calls': null,
      'tool_call_id': null,
      'api_content': null,
      'created_at': 0,
    };
    expect(ChatMessage.fromDb(row3).toolCallId, isNull);
  });

  test('MasteryStatus 双向序列化', () {
    expect(MasteryStatus.mastered.wire, 'mastered');
    expect(MasteryStatusX.fromWire('weak'), MasteryStatus.weak);
    expect(MasteryStatusX.fromWire('未知'), MasteryStatus.unknown);
  });

  test('LlmConfig toMap/fromMap 往返', () {
    final now = DateTime.utc(2026, 8, 6);
    final c = LlmConfig(
      name: 'glm',
      apiUrl: 'https://api.example.com/v1',
      apiKey: 'sk-x',
      model: 'glm-4v',
      supportsVision: true,
      isDefault: true,
      createdAt: now,
    );
    final m = c.toMap();
    expect(m['supports_vision'], 1);
    expect(m['is_default'], 1);
    final back = LlmConfig.fromMap({
      'id': 1,
      ...m,
    });
    expect(back.supportsVision, true);
    expect(back.model, 'glm-4v');
  });

  group('FocusSession', () {
    test('toMap 不含 id 时省略 id 键，进行中态 ended/duration 为 null', () {
      final s = FocusSession(startedAt: DateTime(2026, 8, 10, 9, 0, 0));
      final m = s.toMap();
      expect(m.containsKey('id'), isFalse);
      expect(m['started_at'], DateTime(2026, 8, 10, 9, 0, 0).millisecondsSinceEpoch);
      expect(m.containsKey('ended_at'), isFalse);
      expect(m.containsKey('duration_ms'), isFalse);
    });

    test('toMap 含 id 且已结束时写出全部字段', () {
      final s = FocusSession(
        id: 7,
        startedAt: DateTime(2026, 8, 10, 9, 0, 0),
        endedAt: DateTime(2026, 8, 10, 9, 30, 0),
        durationMs: 1800000,
      );
      final m = s.toMap();
      expect(m['id'], 7);
      expect(m['ended_at'], DateTime(2026, 8, 10, 9, 30, 0).millisecondsSinceEpoch);
      expect(m['duration_ms'], 1800000);
    });

    test('fromMap 往返一致（进行中态）', () {
      final s = FocusSession(
        id: 1,
        startedAt: DateTime(2026, 8, 10, 9, 0, 0),
      );
      final back = FocusSession.fromMap(s.toMap());
      expect(back.id, 1);
      expect(back.startedAt, s.startedAt);
      expect(back.endedAt, isNull);
      expect(back.durationMs, isNull);
    });

    test('fromMap 往返一致（已结束态）', () {
      final s = FocusSession(
        id: 2,
        startedAt: DateTime(2026, 8, 10, 9, 0, 0),
        endedAt: DateTime(2026, 8, 10, 10, 0, 0),
        durationMs: 3600000,
      );
      final back = FocusSession.fromMap(s.toMap());
      expect(back.endedAt, s.endedAt);
      expect(back.durationMs, 3600000);
    });
  });

  group('FocusSessionTopic', () {
    test('toMap/fromMap 往返一致', () {
      final t = FocusSessionTopic(
        id: 5,
        sessionId: 3,
        topicId: 11,
        linkedAt: DateTime(2026, 8, 10, 9, 5, 0),
      );
      final back = FocusSessionTopic.fromMap(t.toMap());
      expect(back.id, 5);
      expect(back.sessionId, 3);
      expect(back.topicId, 11);
      expect(back.linkedAt, DateTime(2026, 8, 10, 9, 5, 0));
    });

    test('toMap 不含 id 时省略 id 键', () {
      final t = FocusSessionTopic(
        sessionId: 3, topicId: 11, linkedAt: DateTime(2026, 8, 10, 9, 5, 0),
      );
      expect(t.toMap().containsKey('id'), isFalse);
    });
  });

  test('Rating round-trip via wire', () {
    for (final r in Rating.values) {
      expect(RatingX.fromWire(r.wire), r);
    }
  });

  test('TopicSchedule fromMap/toMap preserves all fields including nulls', () {
    final s = TopicSchedule(
      topicId: 7, stability: 3.5, difficulty: 6.0, reps: 2, lapses: 1,
      lastReviewedAt: null, dueAt: null,
    );
    final m = s.toMap();
    expect(TopicSchedule.fromMap(m).stability, 3.5);
    expect(TopicSchedule.fromMap(m).dueAt, isNull);
  });

  test('SaveTopicResult.toJson shape', () {
    final r = SaveTopicResult(id: 9, isNew: true, message: '已保存');
    expect(r.toJson(), {'id': 9, 'is_new': true, 'msg': '已保存'});
  });
}
