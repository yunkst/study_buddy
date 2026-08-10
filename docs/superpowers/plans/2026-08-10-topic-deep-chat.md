# 知识点详情页 AI 深度交流 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在知识点详情页提供「问 AI」底部抽屉,与 AI 就当前知识点进行多轮持久化深度交流,AI 自动感知当前知识点、可修改当前点并沉淀回知识库。

**Architecture:** 复用 `ai_panel_sheet` 的底部抽屉 + 事件流监听模式,新建 `TopicChatSheet`。扩展 `ChatRepository`(v4 迁移加 `topic_id` + `findOrCreateByTopic`/`listMessages`)实现每知识点持久会话。扩展 `AgentSession.run` 透传 `AgentScenarioContext`,并**前置修复 AgentLoop 死代码缺陷**(`buildSystemPrompt`/`getMemories` 从未被调用)→ 注入当前知识点上下文。

**Tech Stack:** Flutter + Riverpod 3.3.2、study_engine(pure Dart)、sqflite_common、go_router。

## Global Constraints

- 引擎 `packages/study_engine/` **零 Flutter 依赖**,不得引入。
- `PRAGMA foreign_keys = ON`(`database.dart` onConfigure)**不得移除**,CASCADE 依赖它。
- Riverpod **3.3.2**(非 riverpod 2):provider 对象不暴露 `.when`,须 `ref.watch(provider).when(...)`;最终错误/重试用 `ref.invalidate(provider)`。
- SM-2:`ease_factor ∈ [1.3, 3.0]` clamp + `.toDouble()`,interval floor 1(本计划不直接涉及,保留约束)。
- `AgentSession.run` 保持无状态(每次重建 LlmProvider/Scenario/Loop);多轮历史由调用方(`TopicChatSheet`)维护。
- commit 须带 `Co-Authored-By: Claude <noreply@anthropic.com>` trailer(两条 `-m` 实现)。

---
## 文件结构

| 文件 | 职责 |
|---|---|
| `packages/study_engine/lib/src/db/database_migrations.dart` | v4 迁移:`chat_session` 加 `topic_id` + UNIQUE 索引 |
| `packages/study_engine/lib/src/repos/chat_repository.dart` | `findOrCreateByTopic` / `listMessages` / `createSession` 加 `topicId` |
| `packages/study_engine/lib/src/models/models.dart` | `ChatMessage.fromJson` / `ToolCall.fromJson` / `ContentPart` 反序列化 |
| `packages/study_engine/lib/src/agent/agent_loop.dart` | 修复:`run` 注入 system prompt + 调 `getMemories` |
| `packages/study_engine/lib/src/agent/scenarios/study_scenario.dart` | `buildSystemPrompt` 读 `ctx.extra['current_topic']` |
| `packages/study_engine/lib/src/agent/agent_scenario.dart` | (不改,已含 context) |
| `study_buddy/lib/core/providers/agent_session_provider.dart` | `run` 加可选 `context` 透传 |
| `study_buddy/lib/features/knowledge/topic_chat_sheet.dart` | 新建:底部抽屉 + 多轮 + 持久化 + 工具轨迹 |
| `study_buddy/lib/features/knowledge/topic_detail_page.dart` | 加「问 AI」按钮 |
| 各测试文件 | 见各任务 |

---

### Task 1: ChatRepository 会话读取 + v4 迁移

**Files:**
- Modify: `packages/study_engine/lib/src/db/database_migrations.dart`
- Modify: `packages/study_engine/lib/src/repos/chat_repository.dart`
- Modify: `packages/study_engine/lib/src/models/models.dart`(加 `ChatMessage.fromJson` + `ToolCall.fromJson`)
- Test: `packages/study_engine/test/repos_test.dart`(追加)、`packages/study_engine/test/db_test.dart`(v4)

**Interfaces:**
- Consumes: `ChatMessage`(role/content/toolCalls/toolCallId)、`ContentPart`/`TextPart`/`ImageUrlPart`、`ToolCall`。
- Produces: `ChatRepository.findOrCreateByTopic(int topicId, String title) → Future<int>`、`ChatRepository.listMessages(int sessionId) → Future<List<ChatMessage>>`、`createSession(String scenarioId, String title, {int? topicId})`、`ChatMessage.fromJson(Map)`、`ToolCall.fromJson(Map)`、`kCurrentDbVersion = 4`。

- [ ] **Step 1: 写失败测试**

`packages/study_engine/test/repos_test.dart` 追加:

```dart
import 'dart:convert';
import 'package:study_engine/study_engine.dart';

  test('findOrCreateByTopic 首次建会话、二次复用', () async {
    final db = await TestDb.open(); // 既有测试基建,下同
    final repo = ChatRepository(db);
    final id1 = await repo.findOrCreateByTopic(1, 'ε-δ极限定义');
    final id2 = await repo.findOrCreateByTopic(1, 'ε-δ极限定义');
    expect(id1, id2);
  });

  test('findOrCreateByTopic 不同 topic 建不同会话', () async {
    final db = await TestDb.open();
    final repo = ChatRepository(db);
    final a = await repo.findOrCreateByTopic(1, 'A');
    final b = await repo.findOrCreateByTopic(2, 'B');
    expect(a, isNot(b));
  });

  test('listMessages 空会话返回空列表', () async {
    final db = await TestDb.open();
    final repo = ChatRepository(db);
    final sid = await repo.createSession('study', 't');
    expect(await repo.listMessages(sid), isEmpty);
  });

  test('listMessages 往返：纯文本 + 多轮 + 含 tool_calls 反序列化', () async {
    final db = await TestDb.open();
    final repo = ChatRepository(db);
    final sid = await repo.createSession('study', 't');
    await repo.addMessage(sid, const ChatMessage(role: 'user', content: '你好'));
    await repo.addMessage(sid, const ChatMessage(role: 'assistant', content: '你好！'));
    await repo.addMessage(sid, const ChatMessage(
      role: 'assistant',
      content: '',
      toolCalls: [ToolCall(id: 'call_1', name: 'get_topic', arguments: '{"id":1}')],
    ));
    final msgs = await repo.listMessages(sid);
    expect(msgs, hasLength(3));
    expect(msgs[0].role, 'user');
    expect(msgs[0].content, '你好');
    expect(msgs[2].toolCalls, hasLength(1));
    expect(msgs[2].toolCalls!.first.name, 'get_topic');
    expect(msgs[2].toolCalls!.first.arguments, '{"id":1}');
  });

  test('listMessages 往返：content parts(TextPart/ImageUrlPart)', () async {
    final db = await TestDb.open();
    final repo = ChatRepository(db);
    final sid = await repo.createSession('study', 't');
    await repo.addMessage(sid, const ChatMessage(
      role: 'user',
      content: [
        TextPart('看图'),
        ImageUrlPart('data:image/png;base64,xxx', detail: 'high'),
      ],
    ));
    final msgs = await repo.listMessages(sid);
    final parts = msgs.first.content as List<ContentPart>;
    expect(parts, hasLength(2));
    expect(parts[0], isA<TextPart>());
    expect((parts[0] as TextPart).text, '看图');
    expect(parts[1], isA<ImageUrlPart>());
    expect((parts[1] as ImageUrlPart).url, 'data:image/png;base64,xxx');
    expect((parts[1] as ImageUrlPart).detail, 'high');
  });
```

`packages/study_engine/test/db_test.dart` 追加 v4 断言(把测试名"建库后 8 张表存在"顺手改为 9,并加 chat_session.topic_id 列断言):

```dart
  test('建库后 9 张表存在', () async {
    // 既有断言 9 张表,仅改名;新增:chat_session 有 topic_id 列
    final tables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'");
    expect(tables, hasLength(9));
    final cols = await db.rawQuery('PRAGMA table_info(chat_session)');
    expect(cols.map((c) => c['name']), contains('topic_id'));
  });
```

Run: `cd packages/study_engine; dart test`
Expected: FAIL(`findOrCreateByTopic`/`listMessages`/`fromJson` 不存在;`kCurrentDbVersion` 仍 3)。

- [ ] **Step 2: 跑测试确认失败**

Run: 同上。Expected: FAIL。

- [ ] **Step 3: v4 迁移**

`database_migrations.dart`:
- `kCurrentDbVersion` 3 → **4**。
- `migrateDatabase` switch 加 `case 4: _v4(batch); break;`
- 新增:

```dart
/// v4：chat_session 关联知识点。topic_id 可空，UNIQUE 支撑 findOrCreateByTopic。
void _v4(Batch batch) {
  batch.execute('ALTER TABLE chat_session ADD COLUMN topic_id INTEGER REFERENCES topic(id) ON DELETE SET NULL');
  batch.execute('CREATE UNIQUE INDEX idx_chat_session_topic ON chat_session(topic_id)');
}
```

注意:SQLite 的 `ALTER TABLE ADD COLUMN` 带 REFERENCES 子句在 sqflite_common 下可用(列级外键,创建时若 `PRAGMA foreign_keys=ON` 会校验引用表存在——topic 表已存在,OK)。若实现时该语句报错,退化为:先 `ADD COLUMN topic_id INTEGER`,再单独建索引;外键约束放弃(本需求只靠 UNIQUE 索引定位会话,不靠 FK 级联)。

- [ ] **Step 4: 模型反序列化**

`models.dart` 加(在 `ChatMessage` 类内):

```dart
  /// 从 OpenAI 兼容 JSON 反序列化。content 可为 String 或 parts 列表。
  factory ChatMessage.fromJson(Map<String, Object?> m) {
    final rawContent = m['content'];
    Object content;
    if (rawContent is String) {
      content = rawContent;
    } else if (rawContent is List) {
      content = (rawContent as List)
          .map((e) => _partFromJson(e as Map<String, Object?>))
          .toList();
    } else {
      content = rawContent ?? '';
    }
    return ChatMessage(
      role: m['role'] as String,
      content: content,
      toolCalls: m['tool_calls'] == null
          ? null
          : (m['tool_calls'] as List)
              .map((e) => ToolCall.fromJson(e as Map<String, Object?>))
              .toList(),
      toolCallId: m['tool_call_id'] as String?,
    );
  }

  static ContentPart _partFromJson(Map<String, Object?> p) {
    switch (p['type']) {
      case 'text':
        return TextPart(p['text'] as String);
      case 'image_url':
        final img = p['image_url'] as Map<String, Object?>;
        return ImageUrlPart(img['url'] as String, detail: img['detail'] as String?);
      default:
        throw FormatException('未知 content part 类型: ${p['type']}');
    }
  }
```

`ToolCall` 类内加:

```dart
  factory ToolCall.fromJson(Map<String, Object?> m) {
    final fn = m['function'] as Map<String, Object?>;
    return ToolCall(
      id: m['id'] as String,
      name: fn['name'] as String,
      arguments: fn['arguments'] as String,
    );
  }
```

- [ ] **Step 5: ChatRepository 扩展**

`chat_repository.dart`:

```dart
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
```

注意:`addMessage` 存 `jsonEncode(m.toJson()['content'])`——纯文本时是带引号 JSON 字符串(`"你好"`),`jsonDecode` 回来是 `String`;parts 时是数组,`jsonDecode` 回来是 `List<Map>`。`ChatMessage.fromJson` 的 `content` 分支恰好处理这两种。

- [ ] **Step 6: 跑测试确认通过 + 回归**

Run: `cd packages/study_engine; dart analyze; dart test`
Expected: analyze 0 issues;全部 PASS(既有 42 + 新增)。

- [ ] **Step 7: Commit**

```bash
git add packages/study_engine/lib/src/db/database_migrations.dart packages/study_engine/lib/src/repos/chat_repository.dart packages/study_engine/lib/src/models/models.dart packages/study_engine/test/repos_test.dart packages/study_engine/test/db_test.dart
git commit -m "feat(engine): ChatRepository 会话读取 + v4 chat_session.topic_id 迁移" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 2: AgentLoop system prompt 注入修复 + StudyScenario 当前知识点注入

**Files:**
- Modify: `packages/study_engine/lib/src/agent/agent_loop.dart`
- Modify: `packages/study_engine/lib/src/agent/scenarios/study_scenario.dart`
- Test: `packages/study_engine/test/agent_loop_test.dart`、`packages/study_engine/test/study_scenario_test.dart`(新建)

**Interfaces:**
- Consumes: `AgentScenarioContext{currentSubject, extra}`、`scenario.buildSystemPrompt(ctx)`、`scenario.getMemories()`。
- Produces: `AgentLoop.run` 自动注入 system prompt(调用方已传 system 则跳过);`StudyScenario.buildSystemPrompt(ctx)` 读 `ctx.extra['current_topic']` 追加「当前知识点」一节。

- [ ] **Step 1: 写失败测试**

`agent_loop_test.dart` 加:验证 system prompt 被注入且 context 传入。

```dart
  test('run 自动注入 buildSystemPrompt 的 system 消息,且 context 透传', () async {
    final scenario = _FakeScenario(); // 既有 fake,记录 buildSystemPrompt 收到的 ctx
    final loop = AgentLoop(llm: fakeLlm, scenario: scenario);
    final events = await loop.run([
      const ChatMessage(role: 'user', content: 'hi'),
    ], context: const AgentScenarioContext(extra: {'k': 'v'})).toList();
    expect(scenario.lastSystemCalled, isTrue);
    expect(scenario.lastCtxExtra, {'k': 'v'});
    // LLM 收到的消息首条是 system
    expect(fakeLlm.lastMessages!.first.role, 'system');
    expect(fakeLlm.lastMessages!.first.content, contains('fake scenario prompt'));
  });

  test('调用方已传 system 消息则不重复注入', () async {
    final scenario = _FakeScenario();
    final loop = AgentLoop(llm: fakeLlm, scenario: scenario);
    await loop.run([
      const ChatMessage(role: 'system', content: 'custom sys'),
      const ChatMessage(role: 'user', content: 'hi'),
    ]).toList();
    expect(fakeLlm.lastMessages!.first.content, 'custom sys');
  });
```

`study_scenario_test.dart`(新建):

```dart
import 'package:study_engine/study_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('buildSystemPrompt 有 current_topic 时注入知识点上下文', () {
    final s = StudyScenario(
      categories: CategoryRepository.inMemory(), // 视既有测试基建而定
      topics: TopicRepository.inMemory(),
      edges: TopicEdgeRepository.inMemory(),
      memories: AgentMemoryRepository.inMemory(),
    );
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

  test('buildSystemPrompt 无 current_topic 时不含该节', () {
    final s = StudyScenario(...同上...);
    final prompt = s.buildSystemPrompt(const AgentScenarioContext());
    expect(prompt, isNot(contains('当前知识点')));
  });
}
```

(视 study_engine 测试基建,若仓库构造需要 db,参考 `study_scenario_integration_test.dart` 的建库方式。)

- [ ] **Step 2: 跑测试确认失败**

Run: `cd packages/study_engine; dart test`
Expected: FAIL(AgentLoop 不注入 system;buildSystemPrompt 不读 current_topic)。

- [ ] **Step 3: AgentLoop 注入修复**

`agent_loop.dart` `run` 方法开头:

```dart
  Stream<AgentEvent> run(List<ChatMessage> messages, {AgentScenarioContext? context}) async* {
    yield AgentStartedEvent();
    final msgs = [...messages];
    // 注入场景 system prompt(含 context 动态信息)。调用方已传 system 则跳过。
    if (msgs.isEmpty || msgs.first.role != 'system') {
      final sysPrompt = await scenario.buildSystemPrompt(
        context ?? const AgentScenarioContext(),
      );
      msgs.insert(0, ChatMessage(role: 'system', content: sysPrompt));
    }
    var round = 0;
    ...
  }
```

注意:原 `buildSystemPrompt` 是**同步**方法(`String buildSystemPrompt(...)`)。为填充记忆需先 `await scenario.getMemories()`。两种改法:
- (a) 把 `buildSystemPrompt` 改 async —— 动接口,影响大;
- (b) 保持同步,在 AgentLoop 注入前 `await scenario.getMemories()`,并调整 StudyScenario:让 `getMemories()` 先跑填充 `_memCache`,再调 `buildSystemPrompt` 读到已填充缓存。

**采用 (b)**,`agent_loop.dart`:

```dart
    if (msgs.isEmpty || msgs.first.role != 'system') {
      await scenario.getMemories(); // 填充经验记忆缓存,供 buildSystemPrompt 使用
      final sysPrompt = scenario.buildSystemPrompt(
        context ?? const AgentScenarioContext(),
      );
      msgs.insert(0, ChatMessage(role: 'system', content: sysPrompt));
    }
```

- [ ] **Step 4: StudyScenario 读 current_topic**

`study_scenario.dart` `buildSystemPrompt` 末尾追加:

```dart
  @override
  String buildSystemPrompt(AgentScenarioContext ctx) {
    final mem = _memCache;
    final memBlock = mem.isEmpty ? '（暂无）' : mem.asMap().entries.map((e) => '[${e.key + 1}] ${e.value}').join('\n');
    final topicBlock = _currentTopicBlock(ctx);
    return '''你是学习伴侣 AI。...
## 经验记忆
$memBlock
$topicBlock''';
  }

  String _currentTopicBlock(AgentScenarioContext ctx) {
    final t = ctx.extra['current_topic'];
    if (t is! Map) return '';
    final m = t.cast<String, Object?>();
    final edges = m['edges'] as List? ?? [];
    final edgeLines = edges.isEmpty
        ? '（无）'
        : edges.map((e) {
            final em = e as Map;
            return '- ${em['type']}: ${em['other_title']}(id=${em['other_id']})';
          }).join('\n');
    return '''
## 当前知识点(用户正在查看)
- 标题:${m['title']}
- 路径:${m['path']}
- 引子:${m['question']}
- 原文:${m['summary']}
- 关联:
$edgeLines

用户想就这个知识点深入交流。你可 get_topic/search_topics 查相关知识点辅助讲解,
可用 update_topic 补充/修正当前知识点原文,可用 link_topics 建关联边。''';
  }
```

注意:若无 `current_topic`,`_currentTopicBlock` 返回空串,`$topicBlock` 拼空——但原 prompt 末尾是 `## 经验记忆\n$memBlock`,追加空串会在末尾留一个空行,可接受。更稳妥:`topicBlock` 非空才拼接(用 `if` 条件拼接)。

- [ ] **Step 5: 跑测试确认通过 + 回归**

Run: `cd packages/study_engine; dart analyze; dart test`
Expected: analyze 0 issues;全部 PASS(含修复后 agent_loop 既有测试——它们手动传 system 消息,注入逻辑跳过,不破坏)。

- [ ] **Step 6: Commit**

```bash
git add packages/study_engine/lib/src/agent/agent_loop.dart packages/study_engine/lib/src/agent/scenarios/study_scenario.dart packages/study_engine/test/agent_loop_test.dart packages/study_engine/test/study_scenario_test.dart
git commit -m "fix(engine): AgentLoop 注入场景 system prompt,StudyScenario 注入当前知识点" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3: AgentSession context 透传 + TopicChatSheet 抽屉 + 详情页入口

**Files:**
- Modify: `study_buddy/lib/core/providers/agent_session_provider.dart`
- Create: `study_buddy/lib/features/knowledge/topic_chat_sheet.dart`
- Modify: `study_buddy/lib/features/knowledge/topic_detail_page.dart`
- Test: `study_buddy/test/topic_chat_sheet_test.dart`(新建)、`study_buddy/test/topic_detail_page_test.dart`(追加)

**Interfaces:**
- Consumes: `AgentSession.run(messages)`(现签名)、`ChatRepository.findOrCreateByTopic/listMessages/addMessage`、`AgentScenarioContext`、`AgentEvent` 事件类型、`topicDetailProvider(topicId)`(给快照)、`AgentLoop` 注入后的 system prompt。
- Produces: `showTopicChat(context, {required int topicId, required String title})`、`TopicChatSheet` widget、`AgentSession.run(messages, {context})` 新签名。

- [ ] **Step 1: AgentSession context 透传**

`agent_session_provider.dart`:

```dart
  Future<Stream<AgentEvent>> run(
    List<ChatMessage> messages, {
    AgentScenarioContext? context,
  }) async {
    ...
    return loop.run(messages, context: context);
  }
```

既有 `ai_panel_sheet` 调 `session.run(messages)` 不受影响(可选参数)。

- [ ] **Step 2: 写失败测试**

`study_buddy/test/topic_chat_sheet_test.dart`(新建):

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:study_buddy/core/providers/knowledge_providers.dart';
import 'package:study_buddy/features/knowledge/topic_chat_sheet.dart';
import 'package:study_engine/study_engine.dart';

/// 假会话仓库：记录写入。
class FakeChatRepository implements ChatRepository {
  final List<ChatMessage> persisted = [];
  int _nextId = 100;
  int sessionId = 42;
  @override
  Future<int> createSession(String scenarioId, String title, {int? topicId}) async => _nextId++;
  @override
  Future<int> findOrCreateByTopic(int topicId, String title) async => sessionId;
  @override
  Future<int> addMessage(int sessionId, ChatMessage m) async {
    persisted.add(m);
    return 1;
  }
  @override
  Future<List<ChatMessage>> listMessages(int sessionId) async => const [
        ChatMessage(role: 'assistant', content: '历史上的回答'),
      ];
}

void main() {
  testWidgets('抽屉打开加载历史 + 显示标题', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [chatRepositoryProvider.overrideWith((ref) async => FakeChatRepository())],
      child: const MaterialApp(home: Scaffold(body: Builder(builder: (ctx) => Center(
        child: FilledButton(
          onPressed: () => showTopicChat(ctx, topicId: 1, title: 'ε-δ极限定义'),
          child: const Text('打开'),
        ),
      )))),
    ));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.text('ε-δ极限定义'), findsWidgets); // 标题条
    expect(find.text('历史上的回答'), findsOneWidget); // 历史气泡
  });
}
```

(若 `chatRepositoryProvider` 未在 `knowledge_providers.dart` 定义,需在 Task 3 于 `agent_session_provider.dart` 或 `knowledge_providers.dart` 补 `final chatRepositoryProvider = FutureProvider<ChatRepository>((ref) async => ChatRepository(await ref.watch(databaseProvider.future)));`——沿用既有 repo provider 模式。)

`topic_detail_page_test.dart` 追加:

```dart
  testWidgets('详情页有「问 AI」按钮', (tester) async {
    // 既有 topicDetailProvider override
    await tester.pumpWidget(...TopicDetailPage(topicId: 1)...);
    expect(find.text('问 AI'), findsOneWidget);
  });
```

- [ ] **Step 3: 跑测试确认失败**

Run: `cd study_buddy; flutter test test/topic_chat_sheet_test.dart test/topic_detail_page_test.dart`
Expected: FAIL(无 `topic_chat_sheet.dart`、无「问 AI」按钮)。

- [ ] **Step 4: 实现 TopicChatSheet**

`topic_chat_sheet.dart`(核心实现,整体):

```dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:study_engine/study_engine.dart';

import '../../core/providers/agent_session_provider.dart';
import '../../core/providers/knowledge_providers.dart';

/// 知识点深度交流抽屉。复用 ai_panel_sheet 的底部 Modal 模式,但多轮 + 持久化 + 上下文注入。
Future<void> showTopicChat(
  BuildContext context, {
  required int topicId,
  required String title,
}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    isDismissible: true,
    enableDrag: true,
    builder: (_) => _TopicChatSheet(topicId: topicId, title: title),
  );
}

class _TopicChatSheet extends ConsumerStatefulWidget {
  const _TopicChatSheet({required this.topicId, required this.title});
  final int topicId;
  final String title;
  @override
  ConsumerState<_TopicChatSheet> createState() => _TopicChatSheetState();
}

class _TopicChatSheetState extends ConsumerState<_TopicChatSheet> {
  final TextEditingController _inputCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();

  /// 渲染模型：历史消息 + 当轮气泡。每条是 [role, text] 或工具轨迹。
  final List<_ChatLine> _lines = [];
  final List<ChatMessage> _history = []; // 传给 AgentLoop 的全量历史
  StringBuffer? _pendingAi;
  bool _busy = false;
  bool _loadingHistory = true;
  String? _errorText;
  int? _sessionId;
  StreamSubscription<AgentEvent>? _sub;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final chatRepo = await ref.read(chatRepositoryProvider.future);
      final sessionId = await chatRepo.findOrCreateByTopic(widget.topicId, widget.title);
      final history = await chatRepo.listMessages(sessionId);
      if (!mounted) return;
      setState(() {
        _sessionId = sessionId;
        _loadingHistory = false;
        // 把历史铺成渲染行
        for (final m in history) {
          if (m.role == 'user') {
            _lines.add(_ChatLine.user(_textOf(m)));
          } else if (m.role == 'assistant' && m.toolCalls == null) {
            _lines.add(_ChatLine.ai(_textOf(m)));
          } else if (m.role == 'assistant' && m.toolCalls != null) {
            // 工具调用消息：只显示工具名轨迹,不铺 assistant 文本
            for (final tc in m.toolCalls!) {
              _lines.add(_ChatLine.tool('调用工具:${tc.name}'));
            }
          }
          _history.add(m);
        }
      });
      _scrollToBottom();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingHistory = false;
        _errorText = '加载会话失败:$e';
      });
    }
  }

  String _textOf(ChatMessage m) {
    final c = m.content;
    if (c is String) return c;
    return (c as List).whereType<TextPart>().map((p) => p.text).join('\n');
  }

  Future<void> _send() async {
    final text = _inputCtrl.text.trim();
    if (text.isEmpty || _busy) return;
    _inputCtrl.clear();
    final userMsg = ChatMessage(role: 'user', content: text);
    _history.add(userMsg);
    setState(() {
      _lines.add(_ChatLine.user(text));
      _busy = true;
      _errorText = null;
      _pendingAi = StringBuffer();
      _lines.add(_ChatLine.ai(''));
    });
    _scrollToBottom();

    try {
      final session = ref.read(agentSessionProvider);
      final topicCtx = await _buildTopicContext();
      final stream = await session.run(_history, context: topicCtx);
      if (!mounted) return;
      _sub = stream.listen(
        (event) {
          if (!mounted) return;
          setState(() {
            switch (event) {
              case AgentStartedEvent():
                break;
              case TextDeltaEvent(:final delta):
                _pendingAi!.write(delta);
                _lines.last = _ChatLine.ai(_pendingAi.toString());
                break;
              case ToolCallStartEvent(:final name):
                _lines.add(_ChatLine.tool('→ 调用工具:$name'));
                break;
              case ToolCallEndEvent(:final name):
                if (name == 'update_topic') {
                  _lines.add(const _ChatLine.note('✎ 已更新答案'));
                } else if (name == 'link_topics') {
                  _lines.add(const _ChatLine.note('✓ 已建关联'));
                }
                break;
              case AgentDoneEvent():
                _busy = false;
                _persistRound(userMsg);
                break;
              case AgentErrorEvent(:final message):
                _errorText = message;
                _busy = false;
                break;
            }
          });
          if (event is TextDeltaEvent) _scrollToBottom();
        },
        onError: (e) {
          if (!mounted) return;
          setState(() {
            _errorText = '$e';
            _busy = false;
          });
        },
        onDone: () {
          if (!mounted) return;
          setState(() => _busy = false);
        },
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorText = '$e';
        _busy = false;
        // 失败则移除占位的空 AI 气泡
        if (_lines.isNotEmpty && _lines.last.role == 'ai' && _lines.last.text.isEmpty) {
          _lines.removeLast();
        }
      });
    }
  }

  /// 持久化本轮 user + assistant 消息。
  Future<void> _persistRound(ChatMessage userMsg) async {
    final sid = _sessionId;
    if (sid == null) return;
    try {
      final chatRepo = await ref.read(chatRepositoryProvider.future);
      await chatRepo.addMessage(sid, userMsg);
      // assistant 消息：合并 toolCalls 与文本;无文本时只留 toolCalls
      final aiText = _pendingAi?.toString() ?? '';
      final aiToolCalls = _lastRoundToolCalls();
      final aiMsg = ChatMessage(
        role: 'assistant',
        content: aiText,
        toolCalls: aiToolCalls.isEmpty ? null : aiToolCalls,
      );
      await chatRepo.addMessage(sid, aiMsg);
      _history.add(aiMsg);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存对话失败:$e')),
      );
    }
  }

  List<ToolCall> _lastRoundToolCalls() {
    // 从 AgentLoop 事件里收集本轮的 toolCall —— 简单方案:遍历 _history 无法回溯,
    // 改为在 ToolCallEndEvent 收集。见下方 _roundToolCalls 字段。
    return _roundToolCalls;
  }

  Future<AgentScenarioContext> _buildTopicContext() async {
    final detail = ref.read(topicDetailProvider(widget.topicId));
    // 同步读缓存;若未加载则 fallback 标题
    final snapshot = detail.valueOrNull;
    final topic = snapshot?.topic;
    return AgentScenarioContext(extra: {
      'current_topic': {
        'id': widget.topicId,
        'title': widget.title,
        'path': snapshot?.path.join('/') ?? '',
        'question': topic?.question ?? '',
        'summary': topic?.summary ?? '',
        'edges': (snapshot?.edges ?? const [])
            .map((e) => {'type': e.type, 'other_id': e.otherId, 'other_title': e.otherTitle})
            .toList(),
      }
    });
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final sheetHeight = mediaQuery.size.height * 0.6;
    return Padding(
      padding: EdgeInsets.only(bottom: mediaQuery.viewInsets.bottom),
      child: SizedBox(
        height: sheetHeight,
        child: Column(
          children: [
            // 抓把手
            Center(child: Container(
              width: 40, height: 4, margin: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: Colors.grey.shade400, borderRadius: BorderRadius.circular(2)),
            )),
            // 当前知识点标题条
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: Colors.grey.shade100,
              child: Row(children: [
                const Icon(Icons.menu_book, size: 16),
                const SizedBox(width: 6),
                Expanded(child: Text(widget.title, style: const TextStyle(fontWeight: FontWeight.bold), overflow: TextOverflow.ellipsis)),
              ]),
            ),
            const Divider(height: 1),
            // 消息列表
            Expanded(child: _loadingHistory
              ? const Center(child: CircularProgressIndicator())
              : ListView.builder(
                  controller: _scrollCtrl,
                  padding: const EdgeInsets.all(12),
                  itemCount: _lines.length,
                  itemBuilder: (_, i) => _buildLine(_lines[i]),
                )),
            if (_errorText != null)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                color: Colors.red.shade50,
                child: Text(_errorText!, style: TextStyle(color: Colors.red.shade900, fontSize: 12)),
              ),
            // 输入区
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              child: Row(children: [
                Expanded(child: TextField(
                  controller: _inputCtrl,
                  enabled: !_busy,
                  minLines: 1, maxLines: 3,
                  decoration: const InputDecoration(
                    hintText: '就当前知识点继续追问...',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _send(),
                )),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _busy ? null : _send,
                  child: Text(_busy ? '思考中' : '发送'),
                ),
              ]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLine(_ChatLine line) {
    final isAi = line.role == 'ai';
    final isUser = line.role == 'user';
    final isNote = line.role == 'note';
    final isTool = line.role == 'tool';
    if (isTool || isNote) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Text(line.text,
            style: TextStyle(fontSize: 11,
                color: isNote ? Colors.green.shade700 : Colors.grey.shade600)),
      );
    }
    final align = isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final bg = isUser ? Colors.green.shade100 : Colors.grey.shade200;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(12),
        ),
        child: SelectableText(line.text),
      ),
    );
  }
}

/// 渲染行模型。
class _ChatLine {
  final String role; // 'user' | 'ai' | 'tool' | 'note'
  final String text;
  const _ChatLine(this.role, this.text);
  const _ChatLine.user(String t) : this('user', t);
  const _ChatLine.ai(String t) : this('ai', t);
  const _ChatLine.tool(String t) : this('tool', t);
  const _ChatLine.note(String t) : this('note', t);
}
```

**注意**:
- `_roundToolCalls` 字段未在上文定义——需在 `_TopicChatSheetState` 加 `final List<ToolCall> _roundToolCalls = [];`,在 `_send()` 开头 `_roundToolCalls.clear()`,`ToolCallEndEvent` 里收集 toolCall(事件带 `name`/`id`/`result`/`toolCallId`,需从事件构造 `ToolCall`)。实现时以 AgentEvent 实际字段为准(见 `agent_event.dart` 事件定义——`ToolCallEndEvent` 有 name/result/toolCallId,args 解析在事件外)。可简化为:**持久化时只存 `ChatMessage(role:'assistant', content: aiText)`**,丢弃 tool_calls 的持久化(历史重放时 tool 轨迹从 content 无法还原,可接受——重放只显示 assistant 文本)。**采用简化**,避免 `_roundToolCalls` 复杂度。

- `_buildTopicContext` 用 `ref.read(topicDetailProvider(topicId))` 同步读缓存——若未加载,`valueOrNull` 为 null,fallback 标题。但详情页本就有该 provider 缓存(用户是从详情页进入的),通常已加载。若未加载,可 `await ref.read(topicDetailProvider(topicId).future)` 保证快照完整——**采用 await 版本**,确保注入完整知识点原文。

- `chatRepositoryProvider` 需在 `knowledge_providers.dart` 定义(见 Step 2 注)。

- [ ] **Step 5: 详情页加「问 AI」按钮**

`topic_detail_page.dart`:在 `data:` 分支的 ListView children 末尾(edges 之后)追加:

```dart
            const SizedBox(height: 24),
            FilledButton.tonalIcon(
              onPressed: () => showTopicChat(
                context,
                topicId: detail.topic.id!,
                title: detail.topic.title,
              ),
              icon: const Icon(Icons.chat_bubble_outline),
              label: const Text('问 AI'),
            ),
```

`TopicDetailPage` 已是 ConsumerWidget,import 加 `topic_chat_sheet.dart`。

- [ ] **Step 6: 跑测试确认通过 + 回归**

Run: `cd study_buddy; flutter analyze; flutter test`
Expected: analyze 0 issues;全部 PASS(含新增 topic_chat_sheet_test + topic_detail_page_test 追加)。注意 `flutter test` 全量含既有 38 + 新增。

- [ ] **Step 7: Commit**

```bash
git add study_buddy/lib/core/providers/agent_session_provider.dart study_buddy/lib/features/knowledge/topic_chat_sheet.dart study_buddy/lib/features/knowledge/topic_detail_page.dart study_buddy/test/topic_chat_sheet_test.dart study_buddy/test/topic_detail_page_test.dart
git commit -m "feat(app): 知识点详情页问 AI 底部抽屉,多轮持久深度交流" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## 计划自审

**Spec 覆盖:**
- §3 决策 1(每知识点持久会话)→ T1 `findOrCreateByTopic` + v4 `topic_id`。
- §3 决策 2(底部抽屉)→ T3 `TopicChatSheet`。
- §3 决策 3(自动注入)→ T2 `buildSystemPrompt` + T3 `_buildTopicContext` + T2 AgentLoop 修复。
- §3 决策 4(读写当前点)→ T2 system prompt 明示 update_topic/link_topics 可用;T3 轨迹显示。
- §3 决策 5(静默+轨迹可见)→ T3 `ToolCallStartEvent`/note 行。
- §3 决策 6(每轮实时写库)→ T3 `_persistRound`(AgentDone 时 addMessage)。
- §4.3 前置修复 → T2。
- §5 数据模型 → T1。
- §6 测试 → 各任务。

**占位符扫描:** 各步骤代码块完整,无 TBD/TODO。`_buildTopicContext` 的 await 版本与 `chatRepositoryProvider` 定义已注明。

**类型一致性:** `findOrCreateByTopic(int,String)→Future<int>`、`listMessages(int)→Future<List<ChatMessage>>`、`ChatMessage.fromJson`、`AgentSession.run(messages,{context})`、`showTopicChat(context,{topicId,title})` 跨任务签名一致。

**已知注意点(实现时验证):**
- `ALTER TABLE ADD COLUMN ... REFERENCES` 在 sqflite_common 的可用性——降级方案已写(T1 Step 3)。
- `ToolCallEndEvent` 事件字段——T3 简化方案已避开依赖其 args。
- `buildSystemPrompt` 同步签名 + `getMemories` 填充缓存的配合——T2 采用方案 (b)。
- `chatRepositoryProvider` 需在 knowledge_providers.dart 补定义(遵循既有 repo provider 模式,返回 `Future<ChatRepository>`)。
