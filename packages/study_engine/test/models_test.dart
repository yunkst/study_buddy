import 'package:test/test.dart';
import 'package:study_engine/study_engine.dart';

void main() {
  test('纯文本 ChatMessage 序列化为字符串 content', () {
    final m = const ChatMessage(role: 'user', content: '你好');
    expect(m.toJson(), {'role': 'user', 'content': '你好'});
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
}
