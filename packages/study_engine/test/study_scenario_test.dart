import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';
import 'package:study_engine/study_engine.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  Future<StudyScenario> newScenario() async {
    final sdb = await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    return StudyScenario(
      categories: CategoryRepository(sdb),
      topics: TopicRepository(sdb),
      edges: TopicEdgeRepository(sdb),
      memories: AgentMemoryRepository(sdb),
    );
  }

  test('buildSystemPrompt 有 current_topic 时注入知识点上下文', () async {
    final s = await newScenario();
    final ctx = AgentScenarioContext(extra: {
      'current_topic': {
        'id': 1,
        'title': 'ε-δ极限定义',
        'path': '数学/高等数学/极限',
        'question': '如何用 ε-δ 语言定义极限?',
        'summary': '∀ε>0, ∃δ>0, ...',
        'edges': [],
      }
    });
    final prompt = s.buildSystemPrompt(ctx);
    expect(prompt, contains('ε-δ极限定义'));
    expect(prompt, contains('数学/高等数学/极限'));
    expect(prompt, contains('∀ε>0, ∃δ>0'));
    expect(prompt, contains('当前知识点'));
  });

  test('buildSystemPrompt 无 current_topic 时不含该节', () async {
    final s = await newScenario();
    final prompt = s.buildSystemPrompt(const AgentScenarioContext());
    expect(prompt, isNot(contains('当前知识点')));
  });

  test('buildSystemPrompt current_topic 含关联边时渲染关联', () async {
    final s = await newScenario();
    final ctx = AgentScenarioContext(extra: {
      'current_topic': {
        'id': 1,
        'title': '洛必达法则',
        'path': '数学/高等数学/极限',
        'question': '如何求0/0型极限?',
        'summary': '对分子分母分别求导',
        'edges': [
          {'type': 'prerequisite', 'other_id': 2, 'other_title': '导数'},
        ],
      }
    });
    final prompt = s.buildSystemPrompt(ctx);
    expect(prompt, contains('prerequisite'));
    expect(prompt, contains('导数'));
    expect(prompt, contains('id=2'));
  });
}
