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

  test('提示词含启发式原则段（不直接给答案，引导自查）', () async {
    final prompt = await _prompt();
    expect(prompt, contains('启发式原则'));
    expect(prompt, contains('不直接给最终答案'));
    expect(prompt, contains('不直接说出哪里错了'));
    expect(prompt, contains('引导'));
  });

  test('提示词含计划流程段（create_plan/拆节点/每日任务）', () async {
    final prompt = await _prompt();
    expect(prompt, contains('计划：创建计划'));
    expect(prompt, contains('create_plan'));
    expect(prompt, contains('拆节点原则'));
    expect(prompt, contains('每日任务'));
    expect(prompt, contains('add_assessment'));
  });

  test('提示词含删除原则段（高危、ask_user 确认）', () async {
    final prompt = await _prompt();
    expect(prompt, contains('删除原则'));
    expect(prompt, contains('delete_topic'));
    expect(prompt, contains('delete_category'));
    expect(prompt, contains('ask_user'));
    expect(prompt, contains('不可逆'));
  });
}

Future<String> _prompt() async {
  final sdb = await StudyDatabase.open(
    factory: databaseFactoryFfi,
    path: inMemoryDatabasePath,
  );
  final s = StudyPlanScenario(
    categories: CategoryRepository(sdb),
    topics: TopicRepository(sdb),
    edges: TopicEdgeRepository(sdb),
    memories: AgentMemoryRepository(sdb),
    mastery: MasteryRepository(sdb),
    reviews: ReviewRepository(sdb),
    schedules: TopicScheduleRepository(sdb),
    plans: PlanRepository(sdb),
    dayTasks: PlanDayTaskRepository(sdb),
  );
  final p = s.buildSystemPrompt(const AgentScenarioContext());
  await sdb.close();
  return p;
}
