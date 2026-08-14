import 'package:test/test.dart';
import 'package:study_engine/study_engine.dart';

void main() {
  group('AgentTools.recommendTopics schema', () {
    test('工具名与必填参数正确', () {
      final fn = AgentTools.recommendTopics['function'] as Map<String, dynamic>;
      expect(fn['name'], 'recommend_topics');
      final params = fn['parameters'] as Map<String, dynamic>;
      final props = params['properties'] as Map<String, dynamic>;
      expect(params['required'], ['keyword']);
      expect((props['keyword'] as Map)['type'], 'string');
    });

    test('studyTools 追加为第 12 个工具且名称唯一', () {
      final names = AgentTools.studyTools
          .map((t) => ((t['function'] as Map)['name'] as String))
          .toList();
      expect(names, hasLength(12));
      expect(names.last, 'recommend_topics'); // 追加在末尾,既有索引不受影响
      expect(names.toSet(), hasLength(names.length)); // 无重复工具名
    });
  });
}