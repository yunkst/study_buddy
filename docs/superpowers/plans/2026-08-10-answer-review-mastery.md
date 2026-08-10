# 作答批改与掌握度维护 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让学习伴侣 agent 能批改用户作答、诊断薄弱知识点/技巧、维护掌握度,并产出可复盘的纸感批改卡片。

**Architecture:** 复用已存在但空转的掌握度地基(`MasteryStatus`/`mastery_log`/`MasteryRepository`),新增 3 个 agent 工具(`set_mastery`/`get_mastery`/`save_review`)、1 张 `review` 表存批改明细、提示词阶段化(意图识别→批改流程),前端识别 `save_review` 工具事件渲染纸感卡片与详情页。单 agent 架构,`executeTool` 增加可选 context 透传以注入 `chat_session_id`。

**Tech Stack:** Dart 3 / Flutter / sqflite_common(纯 Dart 包 `study_engine`) / Riverpod(Flutter app `study_buddy`) / 现有 AgentLoop ReAct + LlmProvider。

## Global Constraints

- **engine 掌握度机制零重写**:复用 `MasteryStatus { unknown, learning, mastered, weak }` / `mastery_log` 表 / `MasteryRepository.log/currentStatus/timeline`,不改这三者
- **`chat_session_provider.dart` 数据层零改动**:`ToolEvent(name, result)` 收集逻辑不动,前端靠 `state.toolEvents` 识别 `save_review`
- **无新增第三方依赖**
- 敏感模式:不硬编码 `ixunke`/`xkh5-token`/`Authorization.*Bearer`/`study.keyky.cn` 字面值
- 提示词中文文案保持现有风格
- 现有测试全绿回归(engine 现有 + app 现有 59)
- 测试范式:真实 in-memory SQLite(`databaseFactoryFfi` + `inMemoryDatabasePath`)+ `executeTool` 直调 + `_ScriptedLlm` mock(见 `study_scenario_integration_test.dart`)

## File Structure

### engine(`packages/study_engine/lib`)

- `src/db/database_migrations.dart` — `kCurrentDbVersion` bump 2→3,加 `_v3`(建 `review` 表 + 索引)
- `src/models/models.dart` — 新增 `Review`、`ReviewItem` 模型
- `src/repos/review_repository.dart` — **新建**:`ReviewRepository.save/findById/findBySession`,items JSON 编解码
- `src/repos/mastery_repository.dart` — **零改动**(已就绪)
- `src/agent/agent_scenario.dart` — `executeTool` 签名加可选 `AgentScenarioContext? context` 参数
- `src/agent/agent_loop.dart` — 调用 `scenario.executeTool` 处传入 context
- `src/agent/agent_tools.dart` — `studyTools` 列表追加 `set_mastery`/`get_mastery`/`save_review` 三个 schema
- `src/agent/scenarios/study_scenario.dart` — 构造注入 `MasteryRepository` + `ReviewRepository`;`executeTool` 加 3 个 case;`buildSystemPrompt` 重写(阶段化)
- `study_engine.dart` — barrel 导出加 `review_repository.dart`

### app(`study_buddy/lib`)

- `core/providers/agent_session_provider.dart` — `StudyScenario(...)` 装配注入两个 repo;`loop.run` 传 `context`(extra 带 `chat_session_id`)
- `features/external_qbank/ai_panel_sheet.dart` — `_buildMessageBubble` 识别 `save_review` toolEvent → 渲染 `_ReviewCard`;新增 `_ReviewCard` widget + 详情页路由

### tests

- `packages/study_engine/test/study_scenario_integration_test.dart` — 新增 set_mastery/get_mastery/save_review 直调测试 + AgentLoop mock
- `packages/study_engine/test/mastery_tool_test.dart` — **新建**:掌握度工具专项
- `packages/study_engine/test/review_tool_test.dart` — **新建**:批改工具 + ReviewRepository 专项
- `packages/study_engine/test/system_prompt_test.dart` — **新建**:提示词四段断言
- `study_buddy/test/features/external_qbank/review_card_test.dart` — **新建**:`_ReviewCard` 渲染测试

---

## 阶段 A:engine 纯行为(set_mastery / get_mastery + 提示词阶段化)

### Task 1: set_mastery / get_mastery 工具 + MasteryRepository 注入

**Files:**
- Modify: `packages/study_engine/lib/src/agent/agent_tools.dart`
- Modify: `packages/study_engine/lib/src/agent/scenarios/study_scenario.dart`
- Test: `packages/study_engine/test/mastery_tool_test.dart`(新建)

**Interfaces:**
- Consumes: `MasteryRepository.log(int topicId, MasteryStatus status, {String? reason})` / `MasteryRepository.currentStatus(int topicId)` / `MasteryRepository.timeline(int topicId)`(均已存在,零改动);`MasteryStatus { unknown, learning, mastered, weak }` + `MasteryStatusX.fromWire/wire`
- Produces: `StudyScenario` 构造新增 `required MasteryRepository mastery` 参数;`executeTool` 新增 `set_mastery` / `get_mastery` 两个 case;`AgentTools.studyTools` 追加两条 schema

- [ ] **Step 1: 写失败测试**

`packages/study_engine/test/mastery_tool_test.dart`:
```dart
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';
import 'package:study_engine/study_engine.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  // 与 study_scenario_integration_test 同款装配,多了 mastery
  Future<(StudyScenario, MasteryRepository, TopicRepository)> setup() async {
    final sdb = await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final scenario = StudyScenario(
      categories: CategoryRepository(sdb),
      topics: TopicRepository(sdb),
      edges: TopicEdgeRepository(sdb),
      memories: AgentMemoryRepository(sdb),
      mastery: MasteryRepository(sdb),
      reviews: ReviewRepository(sdb), // Task 3 才有,本 Task 用占位 —— 见下方说明
    );
    return (scenario, MasteryRepository(sdb), TopicRepository(sdb));
  }

  test('set_mastery 落库并更新 currentStatus', () async {
    final (scenario, mastery, topics) = await setup();
    // 先建一个 topic 拿 id
    await scenario.executeTool('save_topic', {
      'path': '数学', 'title': '极限', 'question': 'q', 'summary': 's',
    });
    final t = await topics.findByTitle('极限');
    expect(t, isNotNull);

    final r = await scenario.executeTool('set_mastery', {
      'topic_id': t!.id, 'status': 'weak', 'reason': '求极限题答错',
    });
    expect(r, contains('已记录'));
    expect(await mastery.currentStatus(t.id!), MasteryStatus.weak);
    await (await _dbOf(scenario)).close(); // 见说明:辅助关闭
  });

  test('set_mastery 覆盖:再调 learning 后 currentStatus 变 learning', () async {
    final (scenario, mastery, topics) = await setup();
    await scenario.executeTool('save_topic', {'path': '数学', 'title': '导数', 'question': 'q', 'summary': 's'});
    final t = await topics.findByTitle('导数');

    await scenario.executeTool('set_mastery', {'topic_id': t!.id, 'status': 'weak', 'reason': 'r1'});
    await scenario.executeTool('set_mastery', {'topic_id': t.id, 'status': 'learning', 'reason': 'r2'});
    expect(await mastery.currentStatus(t.id!), MasteryStatus.learning);
  });

  test('set_mastery 非法 status 被拒', () async {
    final (scenario, _, topics) = await setup();
    await scenario.executeTool('save_topic', {'path': '数学', 'title': '积分', 'question': 'q', 'summary': 's'});
    final t = await topics.findByTitle('积分');
    final r = await scenario.executeTool('set_mastery', {
      'topic_id': t!.id, 'status': 'unknown', 'reason': 'r',
    });
    expect(r, contains('status')); // 错误信息提示 status 不合法
  });

  test('get_mastery 返回 current_status 与 recent reason', () async {
    final (scenario, _, topics) = await setup();
    await scenario.executeTool('save_topic', {'path': '数学', 'title': '连续', 'question': 'q', 'summary': 's'});
    final t = await topics.findByTitle('连续');
    await scenario.executeTool('set_mastery', {'topic_id': t!.id, 'status': 'weak', 'reason': '答错'});
    final r = await scenario.executeTool('get_mastery', {'topic_id': t.id});
    expect(r, contains('"current_status"'));
    expect(r, contains('weak'));
    expect(r, contains('答错'));
  });
}

// 辅助:从 scenario 取 db 关闭。实现里 StudyScenario 暴露一个 debug 用 getter 或测试自持 sdb。
// 简化:setup() 改为返回 sdb,本测试直接 await sdb.close()。
Future<dynamic> _dbOf(StudyScenario s) async => s;
```
> **实现者注**:上面 `_dbOf` 是占位。实际把 `setup()` 改为同时返回 `sdb`,测试结尾 `await sdb.close()`。修正后 `setup` 签名:
> `Future<(StudyScenario, MasteryRepository, TopicRepository, StudyDatabase)> setup()` —— 第 4 元素是 sdb,关闭用。把测试里 `(await _dbOf(scenario)).close()` 全改为 `await sdb.close()`。

- [ ] **Step 2: 运行测试确认失败**

Run: `cd packages/study_engine && dart test test/mastery_tool_test.dart`
Expected: FAIL —— `StudyScenario` 构造缺少 `mastery`/`reviews` 参数(编译错误),或 `set_mastery` case 未实现返回 `'未知工具'`。

> **依赖说明**:本 Task 测试里构造 `StudyScenario` 需要 `reviews` 参数,但 `ReviewRepository` 在 Task 3 才创建。为避免编译错误,**本 Task 先用一个临时桩**:在 `review_repository.dart` 创建最小 `ReviewRepository` 空壳(只有类声明 + 构造,无方法),Task 3 再填实现。这样 Task 1 可独立编译运行。Step 3 会建这个桩。

- [ ] **Step 3: 建 ReviewRepository 桩 + MasteryRepository 注入 + 工具实现**

(a) 新建 `packages/study_engine/lib/src/repos/review_repository.dart`(桩,Task 3 填充):
```dart
import '../db/database.dart';

/// 批改记录仓库。Task 3 填充 save/findById/findBySession。
class ReviewRepository {
  final StudyDatabase _db;
  ReviewRepository(this._db);
}
```

(b) 在 `packages/study_engine/lib/study_engine.dart` 的 repos 导出区追加:
```dart
export 'src/repos/review_repository.dart';
```

(c) 修改 `packages/study_engine/lib/src/agent/scenarios/study_scenario.dart` 顶部,构造加两个字段:
```dart
class StudyScenario implements AgentScenario {
  final CategoryRepository categories;
  final TopicRepository topics;
  final TopicEdgeRepository edges;
  final AgentMemoryRepository memories;
  final MasteryRepository mastery;   // 新增
  final ReviewRepository reviews;     // 新增(Task 1 仅注入,executeTool 用不到)

  StudyScenario({
    required this.categories,
    required this.topics,
    required this.edges,
    required this.memories,
    required this.mastery,
    required this.reviews,
  });
```

(d) 在 `executeTool` 的 `switch (name)` 内,`default` 之前加两个 case:
```dart
      case 'set_mastery':
        return _setMastery(
          args['topic_id'] as int,
          args['status'] as String,
          args['reason'] as String,
        );
      case 'get_mastery':
        return _getMastery(args['topic_id'] as int);
```

(e) 在 `_linkTopics` 方法之后、`onNoToolCalls` 之前,加两个私有方法:
```dart
  Future<String> _setMastery(int topicId, String status, String reason) async {
    final parsed = MasteryStatusX.fromWire(status);
    if (parsed == MasteryStatus.unknown) {
      return 'status 不合法(允许 learning/mastered/weak,禁止 unknown)';
    }
    await mastery.log(topicId, parsed, reason: reason);
    return '已记录掌握度: $status (reason: $reason)';
  }

  Future<String> _getMastery(int topicId) async {
    final current = await mastery.currentStatus(topicId);
    final timeline = await mastery.timeline(topicId);
    final recent = timeline.reversed.take(5).toList().reversed.map((m) => {
          'status': m.status.wire,
          'reason': m.reason,
          'changed_at': m.changedAt.toIso8601String(),
        }).toList();
    return jsonEncode({
      'topic_id': topicId,
      'current_status': current.wire,
      'log_count': timeline.length,
      'recent': recent,
    });
  }
```
> `jsonEncode` 已 import 于文件顶部(`import 'dart:convert';`)。`MasteryStatusX` / `MasteryLog` 来自 models。

(f) 修改 `packages/study_engine/lib/src/agent/agent_tools.dart`,在 `studyTools` 列表末尾(`link_topics` 之后)追加两条 schema:
```dart
    'type': 'function',
    'function': {
      'name': 'set_mastery',
      'description': '记录某知识点/技巧的掌握程度(基于一次作答或复习判定)。映射规则:全对→升一级(unknown/weak→learning、learning→mastered、mastered 保持);部分对→learning(已 mastered 则回退 learning);全错→weak。reason 必填,写明判定依据。',
      'parameters': {
        'type': 'object',
        'properties': {
          'topic_id': {'type': 'integer', 'description': '知识点/技巧 id'},
          'status': {'type': 'string', 'enum': ['learning', 'mastered', 'weak'], 'description': '目标掌握状态'},
          'reason': {'type': 'string', 'description': '判定依据,如"洛必达题答错:混淆适用条件"'},
        },
        'required': ['topic_id', 'status', 'reason'],
      },
    },
  },
  {
    'type': 'function',
    'function': {
      'name': 'get_mastery',
      'description': '查询某知识点/技巧的当前掌握程度与最近变更历史。批改前了解现状以决定如何调整。',
      'parameters': {
        'type': 'object',
        'properties': {
          'topic_id': {'type': 'integer', 'description': '知识点/技巧 id'},
        },
        'required': ['topic_id'],
      },
    },
  },
```
> 注意:现有 `agent_tools.dart` 的列表结构是 `List<Map<String, dynamic>>`,每条之间用逗号。追加前确认上一条(`link_topics`)的闭合 `}` 正确。

- [ ] **Step 4: 修正现有装配点 + 测试装配**

`packages/study_engine/test/study_scenario_integration_test.dart` 的 `newScenario` 加两个参数(本 Task reviews 用桩):
```dart
  StudyScenario newScenario(StudyDatabase sdb) => StudyScenario(
        categories: CategoryRepository(sdb),
        topics: TopicRepository(sdb),
        edges: TopicEdgeRepository(sdb),
        memories: AgentMemoryRepository(sdb),
        mastery: MasteryRepository(sdb),
        reviews: ReviewRepository(sdb),
      );
```

`study_buddy/lib/core/providers/agent_session_provider.dart:36` 的 `StudyScenario(...)` 装配同步加:
```dart
    final scenario = StudyScenario(
      categories: categories,
      topics: topics,
      edges: edgesRepo,
      memories: memories,
      mastery: MasteryRepository(db),
      reviews: ReviewRepository(db),
    );
```

- [ ] **Step 5: 运行测试确认通过**

Run: `cd packages/study_engine && dart test test/mastery_tool_test.dart`
Expected: PASS(4 个测试全过)

- [ ] **Step 6: 全量回归**

Run: `cd packages/study_engine && dart analyze && dart test`
Expected: analyze 零 issue;现有 34 + 新 4 全绿

- [ ] **Step 7: app 端编译确认(app 测试下阶段 A 不跑新 case,但装配改动不能破坏现有)**

Run: `cd study_buddy && flutter analyze`
Expected: 零 issue(`ReviewRepository` 桩 + 装配注入编译通过)

- [ ] **Step 8: Commit**

```bash
git add packages/study_engine/lib packages/study_engine/test study_buddy/lib/core/providers/agent_session_provider.dart
git commit -m "feat(engine): set_mastery/get_mastery 工具 + MasteryRepository 注入"
```

---

### Task 2: 提示词阶段化(意图识别 + 批改流程 + 技巧同等待遇)

**Files:**
- Modify: `packages/study_engine/lib/src/agent/scenarios/study_scenario.dart`(仅 `buildSystemPrompt`)
- Test: `packages/study_engine/test/system_prompt_test.dart`(新建)

**Interfaces:**
- Consumes: `StudyScenario.buildSystemPrompt(AgentScenarioContext ctx)`(已存在)
- Produces: 新提示词含 4 个标记段落(意图识别/批改流程/技巧同等待遇/掌握度映射),供 system_prompt_test 断言

- [ ] **Step 1: 写失败测试**

`packages/study_engine/test/system_prompt_test.dart`:
```dart
import 'package:test/test.dart';
import 'package:study_engine/study_engine.dart';

void main() {
  late StudyScenario scenario;

  setUp(() {
    // buildSystemPrompt 不依赖 repo,可传 null(构造需要 repo,用任意值占位)
    // 为避免引入 db,直接测 prompt 文本:本测试用一个轻量构造路径。
    // 见说明:StudyScenario 构造需要 repo —— 测试里用 in-memory db 最稳。
  });

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
    factory: _Factory(), // 占位,见说明
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
  await s.getMemories(); // 填 _memCache
  final p = s.buildSystemPrompt(const AgentScenarioContext());
  await sdb.close();
  return p;
}
```
> **实现者注**:`_Factory()` 占位错误。实际用 `databaseFactoryFfi`:`import 'package:sqflite_common_ffi/sqflite_ffi.dart';` + `setUpAll(sqfliteFfiInit);` + `factory: databaseFactoryFfi`。去掉 `_Factory`,改用真实 ffi。`buildSystemPrompt` 是同步方法(非 async),直接 `s.buildSystemPrompt(const AgentScenarioContext())`。`getMemories()` 是 async,需 await 后 _memCache 才填,但即使不调,memory 块显示"（暂无）"不影响断言——可省略 `getMemories`。最终 `_prompt()` 简化为:开 db → 构造 → `buildSystemPrompt` → 关 db → 返回。

- [ ] **Step 2: 运行测试确认失败**

Run: `cd packages/study_engine && dart test test/system_prompt_test.dart`
Expected: FAIL —— 提示词不含"意图识别"/"批改流程"等(现版只有"分析题目、整理知识库、跟踪掌握状态")

- [ ] **Step 3: 重写 buildSystemPrompt**

`packages/study_engine/lib/src/agent/scenarios/study_scenario.dart` 的 `buildSystemPrompt` 方法整体替换为:
```dart
  @override
  String buildSystemPrompt(AgentScenarioContext ctx) {
    final mem = _memCache;
    final memBlock = mem.isEmpty ? '（暂无）' : mem.asMap().entries.map((e) => '[${e.key + 1}] ${e.value}').join('\n');
    return '''你是学习伴侣 AI。职责是分析题目、批改作答、整理知识库、维护掌握度。

## 意图识别（每次输入先判断）
- 输入含用户作答（手写/文字答案） → 进入「批改流程」
- 纯题目（无作答） → 进入「分析流程」：分析题目涉及的知识点并整理进知识库
- 两者兼备 → 批改为主、分析为辅

## 批改流程（含作答时）
1. 逐题判定：对 / 部分对 / 错，给出解析
2. 从错误与部分对的作答中，识别暴露薄弱的知识点或技巧
3. 对每个薄弱点：search_topics 查是否存在
   - 存在 → get_topic 看详情、get_mastery 看现状；答案需补充/修正 → update_topic(id, summary)
   - 不存在 → save_topic 创建（技巧挂「技巧」分类）
4. set_mastery 维护掌握度，reason 写明判定依据：
   - 全对 → 升一级：unknown/weak→learning、learning→mastered、mastered 保持
   - 部分对 → learning（已 mastered 则回退 learning）
   - 全错 → weak
5. save_review 保存结构化批改明细（逐题对错/解析/涉及知识点），随后引导用户点卡片查看、可追问复盘

## 分析流程（纯题目）
按原有职责：分析题目涉及的知识点，整理进知识库（list/search/get/save/update/link）。

## 技巧与知识点同等待遇
技巧也是知识：按 学科/.../技巧/<名> 挂载；有自己的引子（何时用）与答案（怎么用）；
可建关联边、可设掌握度，处理方式与知识点完全一致。

## 知识点粒度原则（最高优先级）
- 一个知识点 = 一个引子(question) + 一个答案(summary)。
- 粒度必须低：若某内容需要多个引子才能讲清，拆成多个知识点分别保存。
- ❌错误："极限"(含定义/求法/定理) ❌正确："ε-δ极限定义""洛必达法则""夹逼定理"

## 写入前必先查（避免重复）
1. 先 search_topics(keyword) 搜索相关知识点，看是否已存在。
2. 命中 → get_topic(id) 看详情：
   - 答案需补充/修正 → update_topic(id, summary)
   - 识别到与已有知识点的依赖/关联 → link_topics(...)
3. 未命中 → list_topics(path) 找到正确分类挂载位置 → save_topic(path, title, question, summary)

## 分类
- path 形如"数学/高等数学/极限"，不存在的层级会自动创建。
- 知识点必须挂到最具体的分类（挂"极限"而非"高等数学"）。

## 关联边
- prerequisite：学A必须先会B，A依赖B(from=A,to=B)。
- related：无先后的相关知识点。
- 仅在分析出明确关系时建边，不要滥连。

## 经验记忆
$memBlock''';
  }
```
> 原 `buildSystemPrompt` 的 `mem`/`memBlock` 逻辑保留;职责行从"分析题目、整理知识库、跟踪掌握状态"改为"分析题目、批改作答、整理知识库、维护掌握度";新增 4 个段(意图识别/批改流程/技巧同等待遇/掌握度映射在批改流程第4步内联);原 5 段(粒度/先查后写/分类/关联边/经验记忆)保留。"分析流程"段把原职责显式化。

- [ ] **Step 4: 运行测试确认通过**

Run: `cd packages/study_engine && dart test test/system_prompt_test.dart`
Expected: PASS(4 测试全过)

- [ ] **Step 5: 全量回归 + app 编译**

Run: `cd packages/study_engine && dart analyze && dart test && cd ../../study_buddy && flutter analyze`
Expected: engine analyze 零 / engine test 全绿 / app analyze 零

- [ ] **Step 6: Commit**

```bash
git add packages/study_engine/lib/src/agent/scenarios/study_scenario.dart packages/study_engine/test/system_prompt_test.dart
git commit -m "feat(engine): 提示词阶段化(意图识别/批改流程/技巧同等待遇)"
```

---

## 阶段 B:批改工作台(review 表 + save_review + 卡片 UI)

### Task 3: review 表迁移 + Review/ReviewItem 模型 + ReviewRepository

**Files:**
- Modify: `packages/study_engine/lib/src/db/database_migrations.dart`
- Modify: `packages/study_engine/lib/src/models/models.dart`
- Modify: `packages/study_engine/lib/src/repos/review_repository.dart`(替换 Task 1 的桩)
- Test: `packages/study_engine/test/review_tool_test.dart`(新建)

**Interfaces:**
- Consumes: `kCurrentDbVersion`(现为 2)、`migrateDatabase` switch、`StudyDatabase.db`(sqflite `Database`)、`Topic`(`findById`,已存在)
- Produces: `kCurrentDbVersion = 3` + `_v3`(review 表 + idx);`Review { id?, chatSessionId?, summary, items: List<ReviewItem>, createdAt }` + `ReviewItem { seq, question, userAnswer?, verdict, analysis, topicIds: List<int> }`;`ReviewRepository.save({int? chatSessionId, required String summary, required List<ReviewItem> items}) → Future<int>` / `findById(int) → Future<Review?>` / `findBySession(int) → Future<List<Review>>`

- [ ] **Step 1: 写失败测试**

`packages/study_engine/test/review_tool_test.dart`:
```dart
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';
import 'package:study_engine/study_engine.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  Future<StudyDatabase> openDb() => StudyDatabase.open(
        factory: databaseFactoryFfi,
        path: inMemoryDatabasePath,
      );

  test('ReviewRepository.save 落库并返回 id,findById 还原 items', () async {
    final sdb = await openDb();
    final repo = ReviewRepository(sdb);
    final id = await repo.save(
      chatSessionId: 1,
      summary: '批改2题,对1错1',
      items: [
        ReviewItem(seq: 1, question: '1+1=?', userAnswer: '2', verdict: 'correct', analysis: '对', topicIds: const []),
        ReviewItem(seq: 2, question: '2+2=?', userAnswer: '5', verdict: 'wrong', analysis: '应为4', topicIds: const [7]),
      ],
    );
    expect(id, greaterThan(0));

    final got = await repo.findById(id);
    expect(got, isNotNull);
    expect(got!.summary, '批改2题,对1错1');
    expect(got.items.length, 2);
    expect(got.items[1].verdict, 'wrong');
    expect(got.items[1].topicIds, [7]);
    await sdb.close();
  });

  test('findBySession 按 created_at 倒序', () async {
    final sdb = await openDb();
    final repo = ReviewRepository(sdb);
    final a = await repo.save(chatSessionId: 5, summary: 'a', items: const [ReviewItem(seq: 1, question: 'q', verdict: 'correct', analysis: 'x', topicIds: [])]);
    final b = await repo.save(chatSessionId: 5, summary: 'b', items: const [ReviewItem(seq: 1, question: 'q', verdict: 'wrong', analysis: 'x', topicIds: [])]);
    final list = await repo.findBySession(5);
    expect(list.length, 2);
    expect(list.first.id, b); // 倒序:b 后建在前
    expect(list.last.id, a);
    await sdb.close();
  });

  test('chatSessionId 可空:不传也能存', () async {
    final sdb = await openDb();
    final repo = ReviewRepository(sdb);
    final id = await repo.save(
      summary: '无会话批改',
      items: const [ReviewItem(seq: 1, question: 'q', verdict: 'partial', analysis: 'x', topicIds: [])],
    );
    final got = await repo.findById(id);
    expect(got!.chatSessionId, isNull);
    await sdb.close();
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd packages/study_engine && dart test test/review_tool_test.dart`
Expected: FAIL —— `Review` / `ReviewItem` 类型未定义,或 `save` 方法不存在(桩里没实现)

- [ ] **Step 3: 加 db 迁移 v3**

`packages/study_engine/lib/src/db/database_migrations.dart`:
(a) 改版本号:
```dart
const int kCurrentDbVersion = 3;
```
(b) `migrateDatabase` 的 switch 加 case 3:
```dart
      case 3:
        _v3(batch);
        break;
```
(c) 文件末尾加 `_v3`:
```dart
/// v3:批改记录表(单表 + items JSON 明细)。
void _v3(Batch batch) {
  batch.execute('''
    CREATE TABLE review (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      chat_session_id INTEGER,
      summary TEXT NOT NULL,
      items TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      FOREIGN KEY (chat_session_id) REFERENCES chat_session(id)
    )
  ''');
  batch.execute('CREATE INDEX idx_review_session ON review(chat_session_id, created_at)');
}
```

- [ ] **Step 4: 加 Review / ReviewItem 模型**

`packages/study_engine/lib/src/models/models.dart` 末尾(`ToolCall` 类之后)追加:
```dart
/// 批改明细中单题的结构。
class ReviewItem {
  final int seq;
  final String question;
  final String? userAnswer;
  final String verdict; // correct | partial | wrong
  final String analysis;
  final List<int> topicIds;
  const ReviewItem({
    required this.seq,
    required this.question,
    this.userAnswer,
    required this.verdict,
    required this.analysis,
    this.topicIds = const [],
  });

  Map<String, Object?> toJson() => {
        'seq': seq,
        'question': question,
        if (userAnswer != null) 'user_answer': userAnswer,
        'verdict': verdict,
        'analysis': analysis,
        'topic_ids': topicIds,
      };

  factory ReviewItem.fromJson(Map<String, Object?> j) => ReviewItem(
        seq: j['seq'] as int,
        question: j['question'] as String,
        userAnswer: j['user_answer'] as String?,
        verdict: j['verdict'] as String,
        analysis: j['analysis'] as String,
        topicIds: (j['topic_ids'] as List).map((e) => e as int).toList(),
      );
}

/// 一次批改记录(对应 review 表一行,items 反序列化为 List<ReviewItem>)。
class Review {
  final int? id;
  final int? chatSessionId;
  final String summary;
  final List<ReviewItem> items;
  final DateTime createdAt;
  const Review({
    this.id,
    this.chatSessionId,
    required this.summary,
    required this.items,
    required this.createdAt,
  });

  factory Review.fromMap(Map<String, Object?> m) {
    final itemsRaw = jsonDecode(m['items'] as String) as List;
    return Review(
      id: m['id'] as int?,
      chatSessionId: m['chat_session_id'] as int?,
      summary: m['summary'] as String,
      items: itemsRaw.map((e) => ReviewItem.fromJson(e as Map<String, Object?>)).toList(),
      createdAt: DateTime.fromMillisecondsSinceEpoch(m['created_at'] as int),
    );
  }
}
```
> `models.dart` 顶部需 `import 'dart:convert';` 的 `jsonDecode`。检查文件首行是否已 import;若否,加 `import 'dart:convert';`。

- [ ] **Step 5: 实现 ReviewRepository(替换桩)**

`packages/study_engine/lib/src/repos/review_repository.dart` 整体替换为:
```dart
import 'dart:convert';
import '../db/database.dart';
import '../models/models.dart';

/// 批改记录仓库。items 以 JSON 数组存于 review.items 列。
class ReviewRepository {
  final StudyDatabase _db;
  ReviewRepository(this._db);

  Future<int> save({
    int? chatSessionId,
    required String summary,
    required List<ReviewItem> items,
  }) async {
    final itemsJson = jsonEncode(items.map((i) => i.toJson()).toList());
    return _db.db.insert('review', {
      'chat_session_id': chatSessionId,
      'summary': summary,
      'items': itemsJson,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<Review?> findById(int id) async {
    final rows = await _db.db.query('review', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : Review.fromMap(rows.first);
  }

  Future<List<Review>> findBySession(int chatSessionId) async {
    final rows = await _db.db.query(
      'review',
      where: 'chat_session_id = ?',
      whereArgs: [chatSessionId],
      orderBy: 'created_at DESC',
    );
    return rows.map(Review.fromMap).toList();
  }
}
```

- [ ] **Step 6: 运行测试确认通过**

Run: `cd packages/study_engine && dart test test/review_tool_test.dart`
Expected: PASS(3 测试全过)

- [ ] **Step 7: 全量回归(engine 迁移影响所有用 in-memory db 的测试)**

Run: `cd packages/study_engine && dart analyze && dart test`
Expected: 零 issue;全绿(v3 建表在 fresh db 上自动跑,旧测试不受影响)

- [ ] **Step 8: Commit**

```bash
git add packages/study_engine/lib/src/db/database_migrations.dart packages/study_engine/lib/src/models/models.dart packages/study_engine/lib/src/repos/review_repository.dart packages/study_engine/test/review_tool_test.dart
git commit -m "feat(engine): review 表迁移 + Review/ReviewItem 模型 + ReviewRepository"
```

---

### Task 4: save_review 工具 + executeTool context 透传 + chat_session_id 注入

**Files:**
- Modify: `packages/study_engine/lib/src/agent/agent_scenario.dart`(接口)
- Modify: `packages/study_engine/lib/src/agent/agent_loop.dart`(透传 context)
- Modify: `packages/study_engine/lib/src/agent/agent_tools.dart`(save_review schema)
- Modify: `packages/study_engine/lib/src/agent/scenarios/study_scenario.dart`(save_review case)
- Modify: `study_buddy/lib/core/providers/agent_session_provider.dart`(传 context)
- Test: `packages/study_engine/test/review_tool_test.dart`(追加 AgentLoop mock)

**Interfaces:**
- Consumes: `AgentScenarioContext({currentSubject, extra = const {}})`(已存在);`AgentLoop.run(messages, {AgentScenarioContext? context})`(已存在);`ReviewRepository.save` / `ReviewItem`(Task 3)
- Produces: `AgentScenario.executeTool` 签名变为 `Future<String> executeTool(String name, Map<String, dynamic> args, {void Function(String p)? onProgress, String? toolCallId, AgentScenarioContext? context})`;`save_review` 工具;前端经 `context.extra['chat_session_id']` 拿 session

- [ ] **Step 1: 写失败测试(追加到 review_tool_test.dart)**

在 `review_tool_test.dart` 末尾追加:
```dart
  test('AgentLoop mock: save_review 落库 review 表', () async {
    final sdb = await openDb();
    final scenario = StudyScenario(
      categories: CategoryRepository(sdb),
      topics: TopicRepository(sdb),
      edges: TopicEdgeRepository(sdb),
      memories: AgentMemoryRepository(sdb),
      mastery: MasteryRepository(sdb),
      reviews: ReviewRepository(sdb),
    );

    final llm = _ScriptedLlm([
      const [
        LlmStreamChunk(textDelta: '', toolCalls: [
          ToolCall(
            id: 'c1',
            name: 'save_review',
            arguments: '{"summary":"批改1题,错","items":[{"seq":1,"question":"1+1","verdict":"wrong","analysis":"应为2","topic_ids":[]}]}',
          ),
        ])
      ],
      const [LlmStreamChunk(textDelta: '已批改')],
    ]);
    final loop = AgentLoop(llm: llm, scenario: scenario);
    final events = await loop.run(
      [const ChatMessage(role: 'system', content: 'sys')],
      context: const AgentScenarioContext(extra: {'chat_session_id': 42}),
    ).toList();
    expect(events.any((e) => e is ToolCallEndEvent), isTrue);

    final list = await ReviewRepository(sdb).findBySession(42);
    expect(list.length, 1);
    expect(list.first.summary, '批改1题,错');
    expect(list.first.items.first.verdict, 'wrong');
    await sdb.close();
  });
}

class _ScriptedLlm extends LlmProvider {
  _ScriptedLlm(this.script) : super(config: LlmConfig(name: '', apiUrl: '', apiKey: '', model: '', createdAt: DateTime(2026)));
  final List<List<LlmStreamChunk>> script;
  int _i = 0;
  @override
  Stream<LlmStreamChunk> chatStreamWithTools({required List<ChatMessage> messages, required List<Map<String, dynamic>> tools}) {
    final chunks = _i < script.length ? script[_i++] : const [LlmStreamChunk(textDelta: '完成')];
    return Stream.fromIterable(chunks);
  }
}
```
> `_ScriptedLlm` 已在 `study_scenario_integration_test.dart` 定义,但那是另一个文件/隔离的 test runner。本文件需自带一份(或 import)。为避免跨文件冲突,**本测试文件自带 `_ScriptedLlm`**(如上),与 integration test 的同名类互不影响(Dart test 每文件独立)。

- [ ] **Step 2: 运行测试确认失败**

Run: `cd packages/study_engine && dart test test/review_tool_test.dart`
Expected: FAIL —— `executeTool` 不接 context(`save_review` case 未实现,或 context 透传缺失导致 chat_session_id 取不到 → findBySession(42) 返回空)

- [ ] **Step 3: 扩展 executeTool 接口**

`packages/study_engine/lib/src/agent/agent_scenario.dart`,`executeTool` 抽象方法签名加可选 context:
```dart
  Future<String> executeTool(
    String name,
    Map<String, dynamic> args, {
    void Function(String p)? onProgress,
    String? toolCallId,
    AgentScenarioContext? context,
  });
```

- [ ] **Step 4: AgentLoop 透传 context**

`packages/study_engine/lib/src/agent/agent_loop.dart`,把第 60 行的 executeTool 调用改为传 context:
```dart
            result = await scenario.executeTool(tc.name, args, toolCallId: tc.id, context: context);
```
> `context` 是 `run(messages, {AgentScenarioContext? context})` 的参数,在闭包内可见。

- [ ] **Step 5: StudyScenario 实现 save_review case + 接收 context**

`packages/study_engine/lib/src/agent/scenarios/study_scenario.dart`:
(a) `executeTool` 方法签名加 `context`(与抽象对齐):
```dart
  @override
  Future<String> executeTool(String name, Map<String, dynamic> args,
      {void Function(String p)? onProgress, String? toolCallId, AgentScenarioContext? context}) async {
    switch (name) {
      // ...现有 case...
      case 'save_review':
        return _saveReview(args, context);
```
(b) 在 `_getMastery` 之后加 `_saveReview`:
```dart
  Future<String> _saveReview(Map<String, dynamic> args, AgentScenarioContext? ctx) async {
    final summary = args['summary'] as String;
    final itemsRaw = args['items'] as List;
    final items = itemsRaw.map((raw) {
      final m = raw as Map<String, dynamic>;
      final tids = m['topic_ids'];
      return ReviewItem(
        seq: m['seq'] as int,
        question: m['question'] as String,
        userAnswer: m['user_answer'] as String?,
        verdict: m['verdict'] as String,
        analysis: m['analysis'] as String,
        topicIds: tids == null ? const [] : (tids as List).map((e) => e as int).toList(),
      );
    }).toList();
    final sessionId = ctx?.extra['chat_session_id'] as int?;
    final id = await reviews.save(chatSessionId: sessionId, summary: summary, items: items);
    return '已保存批改(共 ${items.length} 题,review_id=$id)';
  }
```

- [ ] **Step 6: 加 save_review 工具 schema**

`packages/study_engine/lib/src/agent/agent_tools.dart`,`studyTools` 末尾(get_mastery 之后)追加:
```dart
  {
    'type': 'function',
    'function': {
      'name': 'save_review',
      'description': '批改完成后保存结构化批改明细(逐题对错/解析/涉及知识点),供卡片展示与复盘对话。调用后前端渲染批改卡片,用户可点进查看、继续探讨。与 set_mastery 各司其职:set_mastery 写掌握度日志,save_review 写批改明细。',
      'parameters': {
        'type': 'object',
        'properties': {
          'summary': {'type': 'string', 'description': '批改摘要,如"批改3题,对1错2,薄弱:洛必达适用条件"'},
          'items': {
            'type': 'array',
            'description': '逐题明细',
            'items': {
              'type': 'object',
              'properties': {
                'seq': {'type': 'integer', 'description': '题序,从1开始'},
                'question': {'type': 'string', 'description': '题目文本'},
                'user_answer': {'type': 'string', 'description': '用户作答(可空)'},
                'verdict': {'type': 'string', 'enum': ['correct', 'partial', 'wrong'], 'description': '判定'},
                'analysis': {'type': 'string', 'description': '解析'},
                'topic_ids': {'type': 'array', 'items': {'type': 'integer'}, 'description': '涉及知识点 id 列表'},
              },
              'required': ['seq', 'question', 'verdict', 'analysis'],
            },
          },
        },
        'required': ['summary', 'items'],
      },
    },
  },
```

- [ ] **Step 7: app 层装配传 context**

`study_buddy/lib/core/providers/agent_session_provider.dart`,把 `loop.run(messages)` 改为传 context。需先拿到当前 chat session id。看 `AgentSession.run` 当前签名(第 36-43 行附近),它接收 messages 并构造 scenario + loop。改 `run` 注入 chat_session_id:

定位 `run` 方法签名(在 `AgentSession` 类内,第 19 行起)。若 `run` 当前是 `Future<Stream<AgentEvent>> run(List<ChatMessage> messages)`,改为:
```dart
  Future<Stream<AgentEvent>> run(List<ChatMessage> messages, {int? chatSessionId}) async {
    // ...现有构造 cfg/categories/topics/edges/memories/llm...
    final loop = AgentLoop(llm: llm, scenario: scenario);
    return loop.run(
      messages,
      context: AgentScenarioContext(extra: chatSessionId == null ? const {} : {'chat_session_id': chatSessionId}),
    );
  }
```
> **实现者注**:先读 `agent_session_provider.dart` 第 1-44 行确认 `run` 与 `AgentSession` 现签名。`chat_session_provider.dart` 调 `session.run(msgs)`(第 84 行)需同步传 `chatSessionId`。但当前会话未必有持久 session id(纯内存多轮),故 `chatSessionId` 可空;**本 Task 先支持"可传",Task 6 决定是否真正接通持久 session id**。本 Task 让 `run` 接受可选参数,`chat_session_provider` 暂不传(保持现状),save_review 的 chatSessionId 为 null(测试已覆盖此路径)。

- [ ] **Step 8: 运行测试确认通过**

Run: `cd packages/study_engine && dart test test/review_tool_test.dart`
Expected: PASS(4 测试全过,含新 mock)

- [ ] **Step 9: 全量回归 + app 编译**

Run: `cd packages/study_engine && dart analyze && dart test && cd ../../study_buddy && flutter analyze`
Expected: 零 issue / 全绿

- [ ] **Step 10: Commit**

```bash
git add packages/study_engine/lib study_buddy/lib/core/providers/agent_session_provider.dart packages/study_engine/test/review_tool_test.dart
git commit -m "feat(engine): save_review 工具 + executeTool context 透传"
```

---

### Task 5: app 装配接通 chat_session_id(可选增强)

**Files:**
- Modify: `study_buddy/lib/core/providers/chat_session_provider.dart`(违反零改动?见说明)
- Modify: `study_buddy/lib/core/providers/agent_session_provider.dart`

> **范围决策**:spec 的全局约束是"`chat_session_provider.dart` 数据层零改动"。本 Task 的目标是让 `save_review` 关联到真实 chat session。但当前会话是**纯内存**(`ChatSessionState` 不持久化),没有持久 session id。要接通需:(a) 在 `chat_session` 表建会话拿 id,或 (b) 接受 save_review 暂不挂 session(卡片靠 review_id 定位)。
>
> **决策:本 Task 标记为可选(deferred)**。理由:卡片渲染靠 review_id(Task 7 前端从 toolEvent 结果解析 review_id),不依赖 chat_session_id;复盘对话在主 session 继续(上下文天然带 save_review 调用)。chat_session_id 接通是"将来按会话归档批改"的增强,当前 YAGNI。
>
> 若 reviewer/用户坚持接通,后续单独 task 处理(需在 `agent_session_provider` 的 `run` 里建/复用 `chat_session` 记录)。**本 Plan 不实现 Task 5**,save_review 的 chatSessionId 保持可空(null)。Task 4 Step 7 已为此预留可选参数。

- [ ] **跳过(已 deferred)**

---

### Task 6: 前端 _ReviewCard 渲染(识别 save_review toolEvent)

**Files:**
- Modify: `study_buddy/lib/features/external_qbank/ai_panel_sheet.dart`
- Test: `study_buddy/test/features/external_qbank/review_card_test.dart`(新建)

**Interfaces:**
- Consumes: `state.messages: List<ChatMessage>`(每条 assistant 消息的 `toolCalls: List<ToolCall>?`,跨轮持久);`ToolCall(name, id, arguments)`(arguments 是原始 JSON 字符串);现有 `_buildMessageBubble` / `_buildAssistantBubble` / `PaperColors`(theme extension)/纸感 token
- Produces: `_ReviewCard` widget(纸感卡片摘要);`_buildMessageBubble` 渲染 assistant 消息时,若该消息 `toolCalls` 含 `name == 'save_review'`,渲染卡片

> **数据源决策(重要)**:不从 `state.toolEvents` 取——它是「当前轮」缓冲,下一轮 `send` 会被清空(`chat_session_provider.dart:77`)。改从**已落库的 assistant 消息**取:含 toolCalls 的 assistant 消息经 `AgentRoundEndEvent` append 进 `state.messages`(`chat_session_provider.dart:145-150`),跨轮持久。故遍历 `state.messages` 里各 assistant 消息的 `toolCalls`,凡 `name=='save_review'` 渲染一张卡片——复盘时不丢。卡片内容(摘要/题数)从该 `ToolCall.arguments`(JSON)解析。

- [ ] **Step 1: 写失败测试**

`study_buddy/test/features/external_qbank/review_card_test.dart`:

> 本测试自包含一份精简 `_ControllableAgentSession`(与 `ai_panel_sheet_test.dart` 同模式,因后者未 export 故自带)。模拟 LLM 一轮 `save_review` 工具调用:发 `ToolCallStartEvent` → `ToolCallEndEvent`(result 含 `review_id=7`)→ `AgentRoundEndEvent`([assistant 消息带 `toolCalls: [ToolCall('save_review', ...)]`, tool 消息])→ `AgentDoneEvent`。pump 后断言卡片(`ValueKey('review_card')`)出现且显示摘要。

```dart
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:study_buddy/core/providers/agent_session_provider.dart';
import 'package:study_buddy/core/providers/screenshot_provider.dart';
import 'package:study_buddy/features/external_qbank/ai_panel_sheet.dart';
import 'package:study_engine/study_engine.dart';

/// 可控假 AgentSession:stream 由外部 StreamController 驱动(同 ai_panel_sheet_test 模式)。
class _ControllableAgentSession extends AgentSession {
  _ControllableAgentSession(super.ref, this._controller);
  final StreamController<AgentEvent> _controller;
  @override
  Future<Stream<AgentEvent>> run(List<ChatMessage> messages) async {
    return _controller.stream;
  }
}

Uint8List _pngBytes() => Uint8List.fromList(base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M8AAAMBAQDJ/pLvAAAAAElFTkSuQmCC'));

void main() {
  testWidgets('save_review 工具完成后,对话流出现批改卡片', (tester) async {
    final screenshot = CapturedScreenshot(_pngBytes(), 'data:image/png;base64,x');
    final controller = StreamController<AgentEvent>();
    addTearDown(controller.close);
    final container = ProviderContainer(overrides: [
      agentSessionProvider.overrideWith((ref) => _ControllableAgentSession(ref, controller)),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: Scaffold(body: Builder(builder: (ctx) {
        return ElevatedButton(
          onPressed: () => showAiPanel(ctx, screenshot: screenshot),
          child: const Text('open'),
        );
      }))),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始分析'));
    await tester.pump();

    // 模拟一轮 save_review 工具调用。
    // arguments 是原始 JSON 字符串(对应 ToolCall.arguments)。
    const args = '{"summary":"批改3题,对1错2","items":[{"seq":1,"question":"求极限","verdict":"wrong","analysis":"应为1"}]}';
    await tester.runAsync(() async {
      controller.add(ToolCallStartEvent('save_review', 'c1'));
      controller.add(ToolCallEndEvent('save_review', '已保存批改(共 1 题,review_id=7)', 'c1'));
      controller.add(AgentRoundEndEvent(newMessages: [
        ChatMessage(role: 'assistant', content: '已批改', toolCalls: [
          ToolCall(id: 'c1', name: 'save_review', arguments: args),
        ]),
        ChatMessage(role: 'tool', content: '已保存批改(共 1 题,review_id=7)', toolCallId: 'c1'),
      ]));
      controller.add(AgentDoneEvent('已批改'));
      await controller.close();
    });
    await tester.pump();
    await tester.pump();

    // 对话流出现纸感批改卡片
    expect(find.byKey(const ValueKey('review_card')), findsOneWidget);
    // 卡片含摘要文案
    expect(find.textContaining('批改'), findsWidgets);
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd study_buddy && flutter test test/features/external_qbank/review_card_test.dart`
Expected: FAIL —— `_ReviewCard` 未定义 / 卡片未渲染(`find.byKey(ValueKey('review_card'))` 0 matches)

- [ ] **Step 3: 实现 _ReviewCard + 渲染接入**

(a) 在 `ai_panel_sheet.dart` 的 assistant 消息渲染处,从**该消息的 `toolCalls`**(非 `state.toolEvents`)识别 `save_review`,渲染卡片。新增私有方法:

```dart
/// 从 assistant 消息的 toolCalls 提取 save_review 调用,渲染对应卡片列表。
/// 数据源是已落库的 messages(跨轮持久),不是 state.toolEvents(每轮清空)。
/// review_id 从对应的 tool 消息(role=='tool', toolCallId 匹配)content 解析。
List<Widget> _reviewCardsFromToolCalls(
    List<ToolCall>? toolCalls, List<ChatMessage> allMessages) {
  if (toolCalls == null) return const [];
  return toolCalls
      .where((tc) => tc.name == 'save_review')
      .map((tc) {
        // 在同轮 tool 消息里按 toolCallId 查 result(含 review_id=N)。
        // tool 消息由 AgentRoundEndEvent 落库(chat_session_provider.dart:145-150),跨轮持久。
        String rawResult = '';
        try {
          final toolMsg = allMessages.firstWhere(
            (m) => m.role == 'tool' && m.toolCallId == tc.id,
          );
          rawResult = _plainText(toolMsg.content);
        } catch (_) {}
        return _ReviewCard(rawArguments: tc.arguments, rawResult: rawResult);
      })
      .toList();
}
```
> `_plainText(content)`:把 `ChatMessage.content`(可能是 `String` 或 `List<ContentPart>`)转纯文本——`_buildUserBubble` 已有同类提取逻辑,抽/复用之。`ChatMessage.toolCallId` 字段已存在(见 `models.dart`)。tool 消息的 content 是工具结果字符串(如 `'已保存批改(共 1 题,review_id=7)'`)。**注意**:`ToolEvent`(UI 类型)只有 `name`/`result` 两字段、无 `toolCallId`,且每轮清空,故**不可**作为 review_id 来源——必须走 tool 消息。

(b) 在 `_buildAssistantBubble` 渲染 assistant 消息时,把 `_reviewCardsFromToolCalls(msg.toolCalls)` 的卡片追加到气泡内容后(或气泡下方)。其他工具仍走现有 `_ToolTrace`。

(c) 新增 `_ReviewCard` widget(文件末尾私有 widget 区)。纸感风格:`PaperColors` 现有字段为 `gold`/`onGold`/`goldContainer`/`stampRed`/`ruleSoft`/`paperHighlight`/`warmShadow`/`polaroidBg`(已读 `paper_extension.dart` 确认,**无 `vermilion`,用 `stampRed`**)。所有 paper 字段可空 + colorScheme 兜底(测试用裸 MaterialApp 无 PaperColors extension):

```dart
class _ReviewCard extends StatelessWidget {
  final String rawArguments; // ToolCall.arguments,原始 JSON
  final String rawResult;    // ToolCallEndEvent.result,含 review_id=N(可空串)
  const _ReviewCard({required this.rawArguments, required this.rawResult});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final paper = theme.extension<PaperColors>();
    final cs = theme.colorScheme;
    // 从 arguments 解析摘要;解析失败兜底"批改报告"
    String summary = '批改报告';
    try {
      final obj = jsonDecode(rawArguments) as Map<String, dynamic>;
      if (obj['summary'] is String) summary = obj['summary'] as String;
    } catch (_) {}
    final match = RegExp(r'review_id=(\d+)').firstMatch(rawResult);
    final reviewId = match == null ? null : int.parse(match.group(1)!);
    return Card(
      key: const ValueKey('review_card'),
      color: paper?.polaroidBg ?? cs.surfaceContainerLow,
      elevation: 2,
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: ListTile(
        leading: Icon(Icons.rate_review, color: paper?.stampRed ?? cs.primary),
        title: Text('批改报告', style: theme.textTheme.titleSmall),
        subtitle: Text(summary, maxLines: 2, overflow: TextOverflow.ellipsis),
        trailing: reviewId == null
            ? null
            : IconButton(
                icon: const Icon(Icons.chevron_right),
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => ReviewDetailPage(reviewId: reviewId!),
                )),
              ),
      ),
    );
  }
}
```
> `ReviewDetailPage` 在 Task 7 实现。本 Task 卡片点击 push 它;Task 7 未完成前可暂 push 一个占位 `Scaffold(body: Center(child: Text('详情待实现')))`,Task 7 填充。`jsonDecode` 需 `import 'dart:convert';`(文件头补)。`PaperColors` 已在文件内 import。

- [ ] **Step 4: 运行测试确认通过**

Run: `cd study_buddy && flutter test test/features/external_qbank/review_card_test.dart`
Expected: PASS

- [ ] **Step 5: 全量回归**

Run: `cd study_buddy && flutter analyze && flutter test`
Expected: 零 issue / 全绿(现有 59 + 新增)

- [ ] **Step 6: Commit**

```bash
git add study_buddy/lib/features/external_qbank/ai_panel_sheet.dart study_buddy/test/features/external_qbank/review_card_test.dart
git commit -m "feat(ui): save_review 触发纸感批改卡片渲染"
```

---

### Task 7: 批改详情页(逐题明细)+ 复盘输入

**Files:**
- Modify: `study_buddy/lib/features/external_qbank/ai_panel_sheet.dart`(填充 `ReviewDetailPage`)
- Modify: `study_buddy/lib/core/providers/agent_session_provider.dart`(暴露 `ReviewRepository` 或加查询 provider)
- Test: `study_buddy/test/features/external_qbank/review_card_test.dart`(追加详情页测试)

**Interfaces:**
- Consumes: `ReviewRepository.findById(int) → Future<Review?>`(Task 3);`Review.items: List<ReviewItem>`;`ReviewItem { seq, question, userAnswer?, verdict, analysis, topicIds }`;`currentChatProvider`(复盘输入追加消息,零改动);`PaperColors` 纸感 token
- Produces: `ReviewDetailPage(reviewId)`,逐题展示 + 底部输入框(发消息走同一 chat session)

- [ ] **Step 1: 写失败测试(追加到 review_card_test.dart)**

> 详情页测试用 `reviewRepositoryProvider` override 注入内存假 repo,避免 widget test 直连真实 db。复盘输入测试监听 `currentChatProvider`,详情页提交后断言 messages 多一条 user 消息。

```dart
  // 在 main() 内追加(与上面 testWidgets 同文件,import 已就绪,需补:
  // import 'package:study_engine/study_engine.dart' 已有;Review/ReviewItem 由它 export)
  // 另需 import 'package:flutter_riverpod/flutter_riverpod.dart' 已有。

  testWidgets('详情页渲染逐题明细', (tester) async {
    // 预存一条 review 的内存假 repo
    final review = Review(
      id: 7,
      chatSessionId: null,
      summary: '批改3题,对1错2',
      items: [
        ReviewItem(seq: 1, question: '求 lim(x→0) sin x / x', userAnswer: '0',
            verdict: 'wrong', analysis: '应为 1', topicIds: const [12]),
      ],
      createdAt: 0,
    );
    final fakeRepo = _FakeReviewRepository({7: review});

    final container = ProviderContainer(overrides: [
      reviewRepositoryProvider.overrideWith((ref) async => fakeRepo),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: ReviewDetailPage(reviewId: 7)),
    ));
    await tester.pumpAndSettle();

    // 摘要可见
    expect(find.textContaining('批改3题'), findsOneWidget);
    // 逐题 question 可见
    expect(find.textContaining('求 lim'), findsOneWidget);
    // 错题徽标(wrong → 朱砂✗)
    expect(find.text('✗'), findsOneWidget);
  });

  testWidgets('详情页输入框发消息走同一 chat session', (tester) async {
    // 详情页底部输入 → 调 currentChatProvider.send → messages 追加 user
    // 用 _ControllableAgentSession 让 send 不卡 busy(stream 不 close)
    final controller = StreamController<AgentEvent>();
    addTearDown(controller.close);
    final fakeRepo = _FakeReviewRepository({7: Review(
      id: 7, chatSessionId: null, summary: 's',
      items: const [], createdAt: 0,
    )});
    final container = ProviderContainer(overrides: [
      agentSessionProvider.overrideWith((ref) => _ControllableAgentSession(ref, controller)),
      reviewRepositoryProvider.overrideWith((ref) async => fakeRepo),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: ReviewDetailPage(reviewId: 7)),
    ));
    await tester.pumpAndSettle();

    // 输入并提交
    await tester.enterText(find.byType(TextField), '第1题为什么错');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    // currentChatProvider 的 messages 多了一条 user 消息
    final state = container.read(currentChatProvider);
    expect(state.messages.any((m) => m.role == 'user'), isTrue);
  });
}

/// 内存假 ReviewRepository,详情页测试用。
class _FakeReviewRepository implements ReviewRepository {
  _FakeReviewRepository(this._store);
  final Map<int, Review> _store;
  @override
  Future<int> save({int? chatSessionId, required String summary, required List<ReviewItem> items}) async {
    throw UnimplementedError();
  }
  @override
  Future<Review?> findById(int id) async => _store[id];
  @override
  Future<List<Review>> findBySession(int chatSessionId) async => const [];
}
```
> **前提依赖**:`Review`/`ReviewItem` 模型与 `ReviewRepository` 抽象在 Task 3 定义并 export。`ReviewRepository` 若是**抽象类**则 `_FakeReviewRepository implements` 它(如上);若是**具体类**(无 abstract 方法),则改用 `extends ReviewRepository` + 覆写 `findById`(构造需 `_FakeReviewRepository._(super(db))` 或直接持有 store)——**实现者先读 Task 3 的 `ReviewRepository` 定义**,按其实际形态(abstract class vs concrete class)调整 fake 写法。`Review`/`ReviewItem` 的构造参数名以 Task 3 实际为准(`userAnswer` vs `user_answer`、`topicIds` vs `topic_ids`、`createdAt` 类型)。

- [ ] **Step 2: 运行测试确认失败**

Run: `cd study_buddy && flutter test test/features/external_qbank/review_card_test.dart`
Expected: FAIL —— `ReviewDetailPage` 未实现 / `reviewRepositoryProvider` 未定义 / `ReviewDetailPage` 非公开(测试 import 不到)

- [ ] **Step 3: 加 reviewRepositoryProvider**

在 `study_buddy/lib/core/providers/agent_session_provider.dart` 末尾加(`databaseProvider` 名已确认,在 `database_provider.dart`):
```dart
final reviewRepositoryProvider = FutureProvider<ReviewRepository>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  return ReviewRepository(db);
});
```

- [ ] **Step 4: 实现 ReviewDetailPage**

在 `ai_panel_sheet.dart` 文件末尾加:
```dart
class ReviewDetailPage extends ConsumerWidget {
  final int reviewId;
  const ReviewDetailPage({required this.reviewId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reviewAsync = ref.watch(reviewRepositoryProvider);
    final inputCtrl = TextEditingController();
    return Scaffold(
      appBar: AppBar(title: const Text('批改详情')),
      body: reviewAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('加载失败: $e')),
        data: (repo) => FutureBuilder<Review?>(
          future: repo.findById(reviewId),
          builder: (_, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            final review = snap.data;
            if (review == null) return const Center(child: Text('批改记录不存在'));
            return Column(
              children: [
                Expanded(child: ListView(
                  padding: const EdgeInsets.all(12),
                  children: [
                    Text(review.summary, style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    ...review.items.map((it) => _ReviewItemTile(item: it)),
                  ],
                )),
                _ReviewReplyBar(controller: inputCtrl, onSubmit: (text) {
                  ref.read(currentChatProvider.notifier).send(text);
                  inputCtrl.clear();
                  Navigator.of(context).pop(); // 回到对话流看回复
                }),
              ],
            );
          },
        ),
      ),
    );
  }
}
```
> `_ReviewItemTile`(逐题:徽标 + question + userAnswer + analysis + topicIds 链接)与 `_ReviewReplyBar`(底部输入)为简单私有 widget,实现者按纸感补全(参考现有 `_Polaroid`/`_UserBubble` 风格)。verdict→徽标:correct→墨绿✓、partial→朱砂◐、wrong→朱砂✗。

- [ ] **Step 5: 运行测试确认通过**

Run: `cd study_buddy && flutter test test/features/external_qbank/review_card_test.dart`
Expected: PASS

- [ ] **Step 6: 全量回归**

Run: `cd study_buddy && flutter analyze && flutter test && cd ../packages/study_engine && dart analyze && dart test`
Expected: 全绿(engine + app)

- [ ] **Step 7: Commit**

```bash
git add study_buddy/lib study_buddy/test/features/external_qbank/review_card_test.dart
git commit -m "feat(ui): 批改详情页逐题明细 + 复盘输入(同 session 追加)"
```

---

## 收尾

### Task 8: 全链路回归 + 视觉验收

**Files:** 无(验证 task)

- [ ] **Step 1: engine 全量**

Run: `cd packages/study_engine && dart analyze && dart test`
Expected: 零 issue / 全绿(原 34 + 新增 mastery 4 + system_prompt 4 + review 4)

- [ ] **Step 2: app 全量**

Run: `cd study_buddy && flutter analyze && flutter test`
Expected: 零 issue / 全绿(原 59 + review_card 新增)

- [ ] **Step 3: 真机视觉验收**

Run: `cd study_buddy && flutter run`(连真机/模拟器)
手动验证:
- 拍一张含手写作答的题目图 → agent 进入批改流程 → 调 set_mastery(掌握度变化)+ save_review → 对话流出现纸感批改卡片
- 点卡片进详情页 → 逐题明细(徽标/解析/涉及知识点)+ 底部输入 → 输入追问 → 回对话流看到 AI 基于批改上下文回答
- 纯题目(无作答)→ 仍走分析流程(不误触发批改)
- 暗色主题(夜读灯下纸)下卡片可读

- [ ] **Step 4: 报告**

回报验收结果。若全绿,用 `superpowers:finishing-a-development-branch` 收尾(本地合并到 master / 建 PR,用户定)。

---

## 风险与处置(执行时参照)

| 风险 | 处置 |
|---|---|
| Task 1 构造 StudyScenario 需 `reviews` 参数,但 ReviewRepository 在 Task 3 | Task 1 先建 `ReviewRepository` 空壳桩(只有构造),Task 3 填实现 —— 已在 Task 1 Step 3(a) 说明 |
| `PaperColors` 字段名 | 已确认(读 `paper_extension.dart`):字段为 `gold`/`onGold`/`goldContainer`/`stampRed`(印章红,无 `vermilion`)/`ruleSoft`/`paperHighlight`/`warmShadow`/`polaroidBg`。Task 6 卡片用 `stampRed`/`polaroidBg`,均 `paper?.x ?? colorScheme` 可空兜底(测试裸 MaterialApp 无 extension) |
| app db provider 名 | 已确认:叫 `databaseProvider`(`core/providers/database_provider.dart`,类型 `FutureProvider<StudyDatabase>`)。Task 7 `reviewRepositoryProvider` 用 `ref.watch(databaseProvider.future)` |
| widget test 接 db 重 | Task 7 用 `reviewRepositoryProvider` + override 注入假 repo,避免 widget test 直连 db |
| LLM 生成的 save_review items 嵌套 JSON 不规范 | `_saveReview` 防御性解析(`topic_ids` null→空数组);`ReviewItem.fromJson` 容错;review_tool_test 覆盖空字段 |
| chat_session_id 接通 | Task 5 deferred,save_review chatSessionId 可空,卡片靠 review_id 定位 |
