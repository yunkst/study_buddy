import 'package:test/test.dart';
import 'package:study_engine/study_engine.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test('提示词含意图识别段', () async {
    final prompt = await _prompt();
    expect(prompt, contains('意图识别'));
    expect(prompt, contains('批改流程'));
    expect(prompt, contains('分析流程'));
  });

  test('提示词含批改流程步骤', () async {
    final prompt = await _prompt();
    expect(prompt, contains('逐题判定'));
    expect(prompt, contains('薄弱'));
    expect(prompt, contains('save_review'));
  });

  test('提示词含技巧同等待遇段', () async {
    final prompt = await _prompt();
    expect(prompt, contains('技巧'));
    expect(prompt, contains('同等待遇'));
  });

  test('提示词含掌握度映射规则', () async {
    final prompt = await _prompt();
    expect(prompt, contains('部分对'));
    expect(prompt, contains('learning'));
    expect(prompt, contains('mastered'));
  });
}

Future<String> _prompt() async {
  final sdb = await StudyDatabase.open(
    factory: databaseFactoryFfi,
    path: inMemoryDatabasePath,
  );
  final s = StudyScenario(
    categories: CategoryRepository(sdb),
    topics: TopicRepository(sdb),
    edges: TopicEdgeRepository(sdb),
    memories: AgentMemoryRepository(sdb),
    mastery: MasteryRepository(sdb),
    reviews: ReviewRepository(sdb),
  );
  final p = s.buildSystemPrompt(const AgentScenarioContext());
  await sdb.close();
  return p;
}
