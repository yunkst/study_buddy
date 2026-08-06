import 'package:test/test.dart';
import 'package:study_engine/study_engine.dart';

void main() {
  test('带图片的消息请求体符合 OpenAI vision 结构', () {
    final m = ChatMessage(
      role: 'user',
      content: const [
        TextPart('分析题目'),
        ImageUrlPart('data:image/png;base64,iVBOR=', detail: 'high'),
      ],
    );
    final json = m.toJson();
    expect(json['role'], 'user');
    final list = json['content'] as List;
    expect(list.last, {
      'type': 'image_url',
      'image_url': {'url': 'data:image/png;base64,iVBOR=', 'detail': 'high'},
    });
  });

  test('tool_calls 消息序列化', () {
    final m = ChatMessage(
      role: 'assistant',
      content: '',
      toolCalls: [const ToolCall(id: 'call_1', name: 'save_topic', arguments: '{"title":"t"}')],
    );
    final json = m.toJson();
    expect((json['tool_calls'] as List).first['function']['name'], 'save_topic');
  });
}
