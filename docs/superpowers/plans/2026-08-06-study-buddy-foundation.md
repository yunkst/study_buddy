# study_buddy 地基阶段（Agent 基座 + 数据层）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 构建可独立验证的最小地基——Agent ReAct 循环 + LLM Provider（含 vision）+ 数据层（8 表 + 7 Repository）+ 2 个真实工具，带集成测试，并接入顶层 app（go_router + 占位首页），全部 `flutter analyze`/`flutter test` 通过、`flutter run -d windows` 可启动。

**Architecture:** 4 层架构。独立纯 Dart 包 `packages/study_engine` 承载 Agent/LLM/DB（不依赖 Flutter），顶层 Flutter app 通过 Riverpod 注入依赖。Agent 采用 ReAct 循环 + AgentScenario 抽象 + OpenAI 兼容 LLM Provider（扩展 vision content）。范式移植自 novel_builder，不抄代码。

**Tech Stack:** Flutter 3.35.7 / Dart 3.9.2 / Riverpod 3.x / go_router / sqflite_common + sqflite_common_ffi / OpenAI 兼容 SSE 流式协议。

## Global Constraints

- **Dart SDK**: `^3.9.2`（与 app 现有 pubspec 一致）。
- **包名/路径**: engine 包名 `study_engine`，位于 `packages/study_engine/`；app 包名 `study_buddy`，位于 `D:\my_space\study\study_buddy\`（已存在的 Flutter 项目）。文档与 plan 位于 `D:\my_space\study\docs\`。
- **engine 不依赖 Flutter**: `study_engine` 的 `pubspec.yaml` **不得**出现 `flutter:` sdk 依赖，也不得 `import 'package:flutter/...'`。仅依赖 `dart:*`、`sqflite_common`、`sqflite_common_ffi`、`path`、`meta`。
- **数据库**: engine 用 `sqflite_common`（接口）+ `sqflite_common_ffi`（实现）。`Database` 门面接收注入的 `DatabaseFactory`。VM 测试与 Windows 桌面生产都用 `databaseFactoryFfi`。
- **测试运行**: engine 内测试用 `flutter test`（在 `packages/study_engine/` 目录执行，Flutter 会正确处理纯 Dart 包）；集成测试用 `sqflite_common_ffi` 初始化内存库。
- **LLM 协议**: OpenAI 兼容 `/chat/completions`，SSE 流式（`stream:true`），工具用 function calling schema。
- **vision content**: `ChatMessage.content` 支持 `String` 或 `List<ContentPart>`，序列化为 OpenAI vision 数组结构。
- **掌握状态**: 日志表驱动（`mastery_log`），当前状态 = 最近一条 log 的 status。
- **代码风格**: 与现有 `study_buddy/lib/main.dart` 一致——中文注释、trailing comma、`const` 构造器、文件聚焦单一职责。
- **无 git 历史**: 项目当前非 git 仓库。Task 0 先 `git init`，此后每个 Task 末尾 commit。
- **YAGNI 边界**: 不做拍照识题/出题业务 UI、不做 dispatch_subagent、不做 chat 回看 UI、不做云端同步。

---

## Task 0: 项目脚手架与 git 初始化

**Files:**
- Create: `packages/study_engine/pubspec.yaml`
- Create: `packages/study_engine/lib/study_engine.dart`
- Create: `packages/study_engine/.gitignore`
- Create: `.gitignore`（仓库根）
- Modify: `study_buddy/pubspec.yaml`（加 go_router、path、study_engine 依赖）

**Interfaces:**
- Consumes: 现有 `study_buddy` Flutter 项目（已有 Riverpod）。
- Produces: `study_engine` package 骨架（可被 app 通过相对路径依赖）；根 git 仓库。

- [ ] **Step 1: 初始化 git 仓库（根目录）**

在 `D:\my_space\study\` 执行：
```bash
git init
```

- [ ] **Step 2: 写根 `.gitignore`**

Create `D:\my_space\study\.gitignore`：
```gitignore
# Dart / Flutter
.dart_tool/
.packages
build/
.flutter-plugins
.flutter-plugins-dependencies
pubspec.lock
!packages/**/pubspec.lock

# IDE
.idea/
.vscode/
*.iml

# OS
.DS_Store
Thumbs.db
```

- [ ] **Step 3: 创建 study_engine 包目录与 pubspec**

Create `packages/study_engine/pubspec.yaml`：
```yaml
name: study_engine
description: "study_buddy 的引擎层：Agent、LLM Provider、数据层。不依赖 Flutter。"
publish_to: 'none'
version: 0.1.0

environment:
  sdk: ^3.9.2

dependencies:
  sqflite_common: ^2.5.4
  path: ^1.9.0
  meta: ^1.16.0

dev_dependencies:
  sqflite_common_ffi: ^2.3.4
  test: ^1.25.0
  lints: ^5.0.0
```

Create `packages/study_engine/.gitignore`：
```gitignore
.dart_tool/
.packages
build/
pubspec.lock
```

- [ ] **Step 4: 创建 barrel 导出文件**

Create `packages/study_engine/lib/study_engine.dart`：
```dart
/// study_engine：study_buddy 的引擎层 barrel 导出。
///
/// 后续任务的模型、Repository、LLM、Agent 导出会逐步追加到此处。
library study_engine;
```

- [ ] **Step 5: 给 app 添加依赖（go_router、path、engine）**

Modify `study_buddy/pubspec.yaml`，在 `dependencies:` 下追加：
```yaml
  go_router: ^14.6.0
  path: ^1.9.0
  study_engine:
    path: ../packages/study_engine
```

执行：
```bash
cd study_buddy
flutter pub get
```
注意：engine 此时还是空包，`study_engine:` 的依赖解析会因为 `pubspec.yaml` 已存在而成功；若提示版本约束问题，按提示调整 `sqflite_common` / `go_router` 版本号。

- [ ] **Step 6: 验证两个包可解析**

```bash
cd packages/study_engine
dart pub get
cd ../../study_buddy
flutter pub get
```
Expected: 两次都成功，无错误。

- [ ] **Step 7: Commit**

```bash
git add .gitignore packages/ study_buddy/pubspec.yaml
git commit -m "chore: 初始化 study_engine 包骨架并接入 app"
```

---

## Task 1: 数据模型层

engine 的纯数据模型，对应数据库表与传输对象。模型不依赖 Flutter，仅用 `dart:*`。

**Files:**
- Create: `packages/study_engine/lib/src/models/models.dart`
- Test: `packages/study_engine/test/models_test.dart`
- Modify: `packages/study_engine/lib/study_engine.dart`（追加 export）

**Interfaces:**
- Consumes: 无（最底层）。
- Produces: `Subject`, `Topic`, `TopicDomain`, `MasteryLog`, `MasteryStatus`, `LlmConfig`, `AgentMemory`, `ChatSession`, `ChatMessage`, `ContentPart`, `TextPart`, `ImageUrlPart`。

- [ ] **Step 1: 写模型文件**

Create `packages/study_engine/lib/src/models/models.dart`：
```dart
/// study_engine 数据模型。对应数据库表，不依赖 Flutter。
library;

import 'dart:convert';

/// 学科。
class Subject {
  final int? id;
  final String name;
  final DateTime createdAt;
  const Subject({this.id, required this.name, required this.createdAt});

  factory Subject.fromMap(Map<String, Object?> m) => Subject(
        id: m['id'] as int?,
        name: m['name'] as String,
        createdAt: DateTime.fromMillisecondsSinceEpoch(m['created_at'] as int),
      );
  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'name': name,
        'created_at': createdAt.millisecondsSinceEpoch,
      };
}

/// 知识点。
class Topic {
  final int? id;
  final int subjectId;
  final int? parentTopicId; // 前置/父子关系，nullable
  final String? domain; // 领域标签，nullable
  final String title;
  final String? summary; // AI 生成后存入
  final DateTime createdAt;
  const Topic({
    this.id,
    required this.subjectId,
    this.parentTopicId,
    this.domain,
    required this.title,
    this.summary,
    required this.createdAt,
  });

  factory Topic.fromMap(Map<String, Object?> m) => Topic(
        id: m['id'] as int?,
        subjectId: m['subject_id'] as int,
        parentTopicId: m['parent_topic_id'] as int?,
        domain: m['domain'] as String?,
        title: m['title'] as String,
        summary: m['summary'] as String?,
        createdAt: DateTime.fromMillisecondsSinceEpoch(m['created_at'] as int),
      );
  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'subject_id': subjectId,
        if (parentTopicId != null) 'parent_topic_id': parentTopicId,
        if (domain != null) 'domain': domain,
        'title': title,
        if (summary != null) 'summary': summary,
        'created_at': createdAt.millisecondsSinceEpoch,
      };
}

/// 学科内领域分类。
class TopicDomain {
  final int? id;
  final int subjectId;
  final String name;
  final DateTime createdAt;
  const TopicDomain({this.id, required this.subjectId, required this.name, required this.createdAt});

  factory TopicDomain.fromMap(Map<String, Object?> m) => TopicDomain(
        id: m['id'] as int?,
        subjectId: m['subject_id'] as int,
        name: m['name'] as String,
        createdAt: DateTime.fromMillisecondsSinceEpoch(m['created_at'] as int),
      );
  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'subject_id': subjectId,
        'name': name,
        'created_at': createdAt.millisecondsSinceEpoch,
      };
}

/// 掌握状态枚举。
enum MasteryStatus { unknown, learning, mastered, weak }

extension MasteryStatusX on MasteryStatus {
  String get wire => name;
  static MasteryStatus fromWire(String s) =>
      MasteryStatus.values.firstWhere((e) => e.name == s, orElse: () => MasteryStatus.unknown);
}

/// 掌握状态变更日志。
class MasteryLog {
  final int? id;
  final int topicId;
  final MasteryStatus status;
  final String? reason;
  final DateTime changedAt;
  const MasteryLog({
    this.id,
    required this.topicId,
    required this.status,
    this.reason,
    required this.changedAt,
  });

  factory MasteryLog.fromMap(Map<String, Object?> m) => MasteryLog(
        id: m['id'] as int?,
        topicId: m['topic_id'] as int,
        status: MasteryStatusX.fromWire(m['status'] as String),
        reason: m['reason'] as String?,
        changedAt: DateTime.fromMillisecondsSinceEpoch(m['changed_at'] as int),
      );
  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'topic_id': topicId,
        'status': status.wire,
        if (reason != null) 'reason': reason,
        'changed_at': changedAt.millisecondsSinceEpoch,
      };
}

/// LLM 供应商配置。
class LlmConfig {
  final int? id;
  final String name;
  final String apiUrl;
  final String apiKey;
  final String model;
  final bool supportsVision;
  final bool isDefault;
  final int sortOrder;
  final DateTime createdAt;
  const LlmConfig({
    this.id,
    required this.name,
    required this.apiUrl,
    required this.apiKey,
    required this.model,
    this.supportsVision = false,
    this.isDefault = false,
    this.sortOrder = 0,
    required this.createdAt,
  });

  factory LlmConfig.fromMap(Map<String, Object?> m) => LlmConfig(
        id: m['id'] as int?,
        name: m['name'] as String,
        apiUrl: m['api_url'] as String,
        apiKey: m['api_key'] as String,
        model: m['model'] as String,
        supportsVision: (m['supports_vision'] as int) == 1,
        isDefault: (m['is_default'] as int) == 1,
        sortOrder: m['sort_order'] as int,
        createdAt: DateTime.fromMillisecondsSinceEpoch(m['created_at'] as int),
      );
  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'name': name,
        'api_url': apiUrl,
        'api_key': apiKey,
        'model': model,
        'supports_vision': supportsVision ? 1 : 0,
        'is_default': isDefault ? 1 : 0,
        'sort_order': sortOrder,
        'created_at': createdAt.millisecondsSinceEpoch,
      };
}

/// agent 经验记忆。
class AgentMemory {
  final int? id;
  final String scenarioId;
  final String content;
  final DateTime createdAt;
  const AgentMemory({this.id, required this.scenarioId, required this.content, required this.createdAt});

  factory AgentMemory.fromMap(Map<String, Object?> m) => AgentMemory(
        id: m['id'] as int?,
        scenarioId: m['scenario_id'] as String,
        content: m['content'] as String,
        createdAt: DateTime.fromMillisecondsSinceEpoch(m['created_at'] as int),
      );
  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'scenario_id': scenarioId,
        'content': content,
        'created_at': createdAt.millisecondsSinceEpoch,
      };
}

/// 对话会话。
class ChatSession {
  final int? id;
  final String scenarioId;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;
  const ChatSession({
    this.id,
    required this.scenarioId,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
  });

  factory ChatSession.fromMap(Map<String, Object?> m) => ChatSession(
        id: m['id'] as int?,
        scenarioId: m['scenario_id'] as String,
        title: m['title'] as String,
        createdAt: DateTime.fromMillisecondsSinceEpoch(m['created_at'] as int),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(m['updated_at'] as int),
      );
  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'scenario_id': scenarioId,
        'title': title,
        'created_at': createdAt.millisecondsSinceEpoch,
        'updated_at': updatedAt.millisecondsSinceEpoch,
      };
}

// ===== vision content parts =====

/// ChatMessage content 的一个片段。sealed，仅 TextPart / ImageUrlPart。
sealed class ContentPart {}

class TextPart extends ContentPart {
  final String text;
  const TextPart(this.text);
}

class ImageUrlPart extends ContentPart {
  final String url; // base64 data URI 或 http URL
  final String? detail; // low / high / auto
  const ImageUrlPart(this.url, {this.detail});
}

/// 对话消息。content 既可纯文本，也可为 ContentPart 列表（vision）。
class ChatMessage {
  final String role;
  final Object content; // String 或 List<ContentPart>
  final List<ToolCall>? toolCalls;
  final String? toolCallId;
  const ChatMessage({
    required this.role,
    required this.content,
    this.toolCalls,
    this.toolCallId,
  });

  /// 序列化为 OpenAI 兼容 JSON 结构（含 vision content 数组）。
  Map<String, Object?> toJson() {
    Object jsonContent;
    if (content is String) {
      jsonContent = content as String;
    } else {
      final parts = content as List<ContentPart>;
      jsonContent = parts.map(_partToJson).toList();
    }
    final m = <String, Object?>{'role': role, 'content': jsonContent};
    if (toolCalls != null) {
      m['tool_calls'] = toolCalls!.map((t) => t.toJson()).toList();
    }
    if (toolCallId != null) m['tool_call_id'] = toolCallId;
    return m;
  }

  static Map<String, Object?> _partToJson(ContentPart p) {
    switch (p) {
      case TextPart(:final text):
        return {'type': 'text', 'text': text};
      case ImageUrlPart(:final url, :final detail):
        final img = <String, Object?>{'url': url};
        if (detail != null) img['detail'] = detail;
        return {'type': 'image_url', 'image_url': img};
    }
  }
}

/// OpenAI function calling 的工具调用。
class ToolCall {
  final String id; // 如 "call_abc"
  final String name;
  final String arguments; // 原始 JSON 字符串
  const ToolCall({required this.id, required this.name, required this.arguments});

  Map<String, Object?> toJson() => {
        'id': id,
        'type': 'function',
        'function': {'name': name, 'arguments': arguments},
      };
}
```

- [ ] **Step 2: 追加 barrel 导出**

Modify `packages/study_engine/lib/study_engine.dart`，在 `library study_engine;` 后加：
```dart
export 'src/models/models.dart';
```

- [ ] **Step 3: 写失败测试**

Create `packages/study_engine/test/models_test.dart`：
```dart
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
```

- [ ] **Step 4: 运行测试，验证失败（如未导出则报错）**

Run: `cd packages/study_engine && flutter test test/models_test.dart`
Expected: FAIL（export 已加则可能直接 PASS；若报错按提示修正）。

- [ ] **Step 5: 运行测试，验证通过**

Run: `cd packages/study_engine && flutter test test/models_test.dart`
Expected: PASS（All tests passed）。

- [ ] **Step 6: Commit**

```bash
git add packages/study_engine/lib packages/study_engine/test
git commit -m "feat(engine): 数据模型层（8 表模型 + vision content parts）"
```

---

## Task 2: 数据库迁移与 Database 门面

**Files:**
- Create: `packages/study_engine/lib/src/db/database_migrations.dart`
- Create: `packages/study_engine/lib/src/db/database.dart`
- Create: `packages/study_engine/test/db_test.dart`
- Modify: `packages/study_engine/lib/study_engine.dart`

**Interfaces:**
- Consumes: `sqflite_common`（`DatabaseFactory`, `Database`）、`sqflite_common_ffi`（测试注入）。
- Produces: `kCurrentDbVersion`（=1）、`migrateDatabase(db, from, to)`、`StudyDatabase.open({factory, path})` 返回持有 `Database` 的门面。

- [ ] **Step 1: 写迁移文件**

Create `packages/study_engine/lib/src/db/database_migrations.dart`：
```dart
import 'package:sqflite_common/sqflite_dev.dart';

/// 当前数据库版本号。每加一张表/字段 +1。
const int kCurrentDbVersion = 1;

/// 执行迁移：按版本号顺序升级。from==0 表示全新建库。
Future<void> migrateDatabase(Database db, int from, int to) async {
  final batch = db.batch();
  for (var v = from + 1; v <= to; v++) {
    switch (v) {
      case 1:
        _v1(batch);
        break;
      default:
        throw StateError('未知数据库版本: $v');
    }
  }
  await batch.commit();
}

/// v1：建齐 8 张表。
void _v1(Batch batch) {
  batch.execute('''
    CREATE TABLE subject (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL UNIQUE,
      created_at INTEGER NOT NULL
    )
  ''');
  batch.execute('''
    CREATE TABLE topic (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      subject_id INTEGER NOT NULL,
      parent_topic_id INTEGER,
      domain TEXT,
      title TEXT NOT NULL,
      summary TEXT,
      created_at INTEGER NOT NULL,
      FOREIGN KEY (subject_id) REFERENCES subject(id)
    )
  ''');
  batch.execute('''
    CREATE TABLE topic_domain (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      subject_id INTEGER NOT NULL,
      name TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      FOREIGN KEY (subject_id) REFERENCES subject(id)
    )
  ''');
  batch.execute('''
    CREATE TABLE mastery_log (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      topic_id INTEGER NOT NULL,
      status TEXT NOT NULL,
      reason TEXT,
      changed_at INTEGER NOT NULL,
      FOREIGN KEY (topic_id) REFERENCES topic(id)
    )
  ''');
  batch.execute('CREATE INDEX idx_mastery_topic ON mastery_log(topic_id, changed_at)');
  batch.execute('''
    CREATE TABLE llm_config (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      api_url TEXT NOT NULL,
      api_key TEXT NOT NULL,
      model TEXT NOT NULL,
      supports_vision INTEGER NOT NULL DEFAULT 0,
      is_default INTEGER NOT NULL DEFAULT 0,
      sort_order INTEGER NOT NULL DEFAULT 0,
      created_at INTEGER NOT NULL
    )
  ''');
  batch.execute('''
    CREATE TABLE agent_memory (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      scenario_id TEXT NOT NULL,
      content TEXT NOT NULL,
      created_at INTEGER NOT NULL
    )
  ''');
  batch.execute('''
    CREATE TABLE chat_session (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      scenario_id TEXT NOT NULL,
      title TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    )
  ''');
  batch.execute('''
    CREATE TABLE chat_message (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id INTEGER NOT NULL,
      role TEXT NOT NULL,
      content TEXT NOT NULL,
      tool_calls TEXT,
      tool_call_id TEXT,
      created_at INTEGER NOT NULL,
      FOREIGN KEY (session_id) REFERENCES chat_session(id)
    )
  ''');
}
```

- [ ] **Step 2: 写 Database 门面**

Create `packages/study_engine/lib/src/db/database.dart`：
```dart
import 'package:sqflite_common/sqlite_api.dart';
import 'package:sqflite_common/sqflite_dev.dart';
import 'database_migrations.dart';

/// 持有 SQLite 连接的门面。factory 由调用方注入（生产/测试各异）。
class StudyDatabase {
  final Database db;
  StudyDatabase._(this.db);

  /// 打开/创建数据库。factory 为 null 时由调用环境提供（app 用 sqflite/sqflite_common_ffi）。
  static Future<StudyDatabase> open({
    required DatabaseFactory factory,
    required String path,
  }) async {
    final db = await factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: kCurrentDbVersion,
        onCreate: (db, _) => migrateDatabase(db, 0, kCurrentDbVersion),
        onUpgrade: (db, oldV, newV) => migrateDatabase(db, oldV, newV),
      ),
    );
    return StudyDatabase._(db);
  }

  Future<void> close() => db.close();
}
```

- [ ] **Step 3: 追加 barrel 导出**

Modify `packages/study_engine/lib/study_engine.dart`，追加：
```dart
export 'src/db/database_migrations.dart' show kCurrentDbVersion, migrateDatabase;
export 'src/db/database.dart';
```

- [ ] **Step 4: 写失败测试（ffi 内存库建库验证）**

Create `packages/study_engine/test/db_test.dart`：
```dart
import 'package:sqflite_common/sqlite_api.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';
import 'package:study_engine/study_engine.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  test('建库后 8 张表存在', () async {
    final factory = databaseFactoryFfi;
    final dbPath = inMemoryDatabasePath;
    final sdb = await StudyDatabase.open(factory: factory, path: dbPath);
    final tables = await sdb.db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name",
    );
    final names = tables.map((r) => r['name'] as String).toSet();
    for (final t in [
      'subject', 'topic', 'topic_domain', 'mastery_log',
      'llm_config', 'agent_memory', 'chat_session', 'chat_message',
    ]) {
      expect(names, contains(t), reason: '缺表: $t');
    }
    await sdb.close();
  });

  test('重复 open 同一内存库不出错', () async {
    final factory = databaseFactoryFfi;
    final sdb = await StudyDatabase.open(factory: factory, path: inMemoryDatabasePath);
    await sdb.close();
    expect(true, isTrue);
  });
}
```

- [ ] **Step 5: 运行测试，验证失败**

Run: `cd packages/study_engine && flutter test test/db_test.dart`
Expected: FAIL（Database/迁移文件若未生效则报错；实现已写应直接进入下一步验证）。

- [ ] **Step 6: 运行测试，验证通过**

Run: `cd packages/study_engine && flutter test test/db_test.dart`
Expected: PASS。

- [ ] **Step 7: Commit**

```bash
git add packages/study_engine
git commit -m "feat(engine): SQLite 迁移 v1 建 8 表 + Database 门面"
```

---

## Task 3: Repository 第一批（Subject + Topic）

**Files:**
- Create: `packages/study_engine/lib/src/repos/subject_repository.dart`
- Create: `packages/study_engine/lib/src/repos/topic_repository.dart`
- Create: `packages/study_engine/test/repos_test.dart`
- Modify: `packages/study_engine/lib/study_engine.dart`

**Interfaces:**
- Consumes: `StudyDatabase`（Task 2）、`Subject`/`Topic` 模型（Task 1）。
- Produces:
  - `SubjectRepository`: `Future<Subject> ensureCreate(String name)`、`Future<Subject?> findByName(String name)`、`Future<List<Subject>> all()`
  - `TopicRepository`: `Future<int> insert(Topic t)`、`Future<Topic?> findById(int id)`、`Future<List<Topic>> queryBySubject(int subjectId, {String? domain})`、`Future<List<Topic>> queryByParent(int parentId)`

- [ ] **Step 1: 写 SubjectRepository**

Create `packages/study_engine/lib/src/repos/subject_repository.dart`：
```dart
import '../db/database.dart';
import '../models/models.dart';

class SubjectRepository {
  final StudyDatabase _db;
  SubjectRepository(this._db);

  /// 按名查找；不存在返回 null。
  Future<Subject?> findByName(String name) async {
    final rows = await _db.db.query('subject', where: 'name = ?', whereArgs: [name], limit: 1);
    return rows.isEmpty ? null : Subject.fromMap(rows.first);
  }

  /// 若不存在则创建，返回该学科。用于 save_topic 按需建学科。
  Future<Subject> ensureCreate(String name) async {
    final existing = await findByName(name);
    if (existing != null) return existing;
    final s = Subject(name: name, createdAt: DateTime.now());
    final id = await _db.db.insert('subject', s.toMap());
    return Subject(id: id, name: name, createdAt: s.createdAt);
  }

  Future<List<Subject>> all() async {
    final rows = await _db.db.query('subject', orderBy: 'name');
    return rows.map(Subject.fromMap).toList();
  }
}
```

- [ ] **Step 2: 写 TopicRepository**

Create `packages/study_engine/lib/src/repos/topic_repository.dart`：
```dart
import '../db/database.dart';
import '../models/models.dart';

class TopicRepository {
  final StudyDatabase _db;
  TopicRepository(this._db);

  Future<int> insert(Topic t) => _db.db.insert('topic', t.toMap());

  Future<Topic?> findById(int id) async {
    final rows = await _db.db.query('topic', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : Topic.fromMap(rows.first);
  }

  /// 按学科查询；domain 非空时按领域过滤。
  Future<List<Topic>> queryBySubject(int subjectId, {String? domain}) async {
    final rows = domain == null
        ? await _db.db.query('topic', where: 'subject_id = ?', whereArgs: [subjectId])
        : await _db.db.query('topic', where: 'subject_id = ? AND domain = ?', whereArgs: [subjectId, domain]);
    return rows.map(Topic.fromMap).toList();
  }

  Future<List<Topic>> queryByParent(int parentId) async {
    final rows = await _db.db.query('topic', where: 'parent_topic_id = ?', whereArgs: [parentId]);
    return rows.map(Topic.fromMap).toList();
  }
}
```

- [ ] **Step 3: 追加 barrel 导出**

Modify `packages/study_engine/lib/study_engine.dart`，追加：
```dart
export 'src/repos/subject_repository.dart';
export 'src/repos/topic_repository.dart';
```

- [ ] **Step 4: 写失败测试**

Create `packages/study_engine/test/repos_test.dart`：
```dart
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';
import 'package:study_engine/study_engine.dart';

StudyDatabase _fresh() {
  sqfliteFfiInit();
  return StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
}

void main() {
  late StudyDatabase sdb;
  setUp(() async => sdb = await _fresh());
  tearDown(() async => await sdb.close());

  test('SubjectRepository.ensureCreate 幂等', () async {
    final repo = SubjectRepository(sdb);
    final s1 = await repo.ensureCreate('数学');
    final s2 = await repo.ensureCreate('数学');
    expect(s1.id, s2.id);
    expect(await repo.all(), hasLength(1));
  });

  test('TopicRepository 增查', () async {
    final subjects = SubjectRepository(sdb);
    final topics = TopicRepository(sdb);
    final math = await subjects.ensureCreate('数学');
    final id = await topics.insert(Topic(
      subjectId: math.id!,
      domain: '代数',
      title: '一元二次方程',
      createdAt: DateTime.now(),
    ));
    final got = await topics.findById(id);
    expect(got?.title, '一元二次方程');
    expect(await topics.queryBySubject(math.id!), hasLength(1));
    expect(await topics.queryBySubject(math.id!, domain: '几何'), isEmpty);
  });
}
```

- [ ] **Step 5: 运行测试，验证失败**

Run: `cd packages/study_engine && flutter test test/repos_test.dart`
Expected: FAIL（Repository 未导出/未实现时报错）。

- [ ] **Step 6: 运行测试，验证通过**

Run: `cd packages/study_engine && flutter test test/repos_test.dart`
Expected: PASS。

- [ ] **Step 7: Commit**

```bash
git add packages/study_engine
git commit -m "feat(engine): Subject + Topic Repository"
```

---

## Task 4: Repository 第二批（Mastery + TopicDomain）

**Files:**
- Create: `packages/study_engine/lib/src/repos/mastery_repository.dart`
- Create: `packages/study_engine/lib/src/repos/topic_domain_repository.dart`
- Modify: `packages/study_engine/test/repos_test.dart`（追加用例）
- Modify: `packages/study_engine/lib/study_engine.dart`

**Interfaces:**
- Consumes: `StudyDatabase`、`MasteryLog`/`MasteryStatus`/`TopicDomain`。
- Produces:
  - `MasteryRepository`: `Future<int> log(int topicId, MasteryStatus status, {String? reason})`、`Future<MasteryStatus> currentStatus(int topicId)`、`Future<List<MasteryLog>> timeline(int topicId)`
  - `TopicDomainRepository`: `Future<int> insert(TopicDomain d)`、`Future<List<TopicDomain>> queryBySubject(int subjectId)`

- [ ] **Step 1: 写 MasteryRepository**

Create `packages/study_engine/lib/src/repos/mastery_repository.dart`：
```dart
import '../db/database.dart';
import '../models/models.dart';

class MasteryRepository {
  final StudyDatabase _db;
  MasteryRepository(this._db);

  /// 记录一条状态变更。
  Future<int> log(int topicId, MasteryStatus status, {String? reason}) {
    return _db.db.insert('mastery_log', MasteryLog(
      topicId: topicId,
      status: status,
      reason: reason,
      changedAt: DateTime.now(),
    ).toMap());
  }

  /// 当前状态 = 最近一条 log。无记录返回 unknown。
  Future<MasteryStatus> currentStatus(int topicId) async {
    final rows = await _db.db.query(
      'mastery_log',
      where: 'topic_id = ?',
      whereArgs: [topicId],
      orderBy: 'changed_at DESC',
      limit: 1,
    );
    if (rows.isEmpty) return MasteryStatus.unknown;
    return MasteryLog.fromMap(rows.first).status;
  }

  /// 完整时间线，用于遗忘曲线。
  Future<List<MasteryLog>> timeline(int topicId) async {
    final rows = await _db.db.query(
      'mastery_log',
      where: 'topic_id = ?',
      whereArgs: [topicId],
      orderBy: 'changed_at ASC',
    );
    return rows.map(MasteryLog.fromMap).toList();
  }
}
```

- [ ] **Step 2: 写 TopicDomainRepository**

Create `packages/study_engine/lib/src/repos/topic_domain_repository.dart`：
```dart
import '../db/database.dart';
import '../models/models.dart';

class TopicDomainRepository {
  final StudyDatabase _db;
  TopicDomainRepository(this._db);

  Future<int> insert(TopicDomain d) => _db.db.insert('topic_domain', d.toMap());

  Future<List<TopicDomain>> queryBySubject(int subjectId) async {
    final rows = await _db.db.query('topic_domain', where: 'subject_id = ?', whereArgs: [subjectId]);
    return rows.map(TopicDomain.fromMap).toList();
  }
}
```

- [ ] **Step 3: 追加 barrel 导出**

Modify `packages/study_engine/lib/study_engine.dart`，追加：
```dart
export 'src/repos/mastery_repository.dart';
export 'src/repos/topic_domain_repository.dart';
```

- [ ] **Step 4: 写失败测试（追加到 repos_test.dart）**

在 `packages/study_engine/test/repos_test.dart` 的 `main()` 内追加：
```dart
  test('MasteryRepository 日志驱动当前状态', () async {
    final subjects = SubjectRepository(sdb);
    final topics = TopicRepository(sdb);
    final mastery = MasteryRepository(sdb);
    final math = await subjects.ensureCreate('数学');
    final tid = await topics.insert(Topic(subjectId: math.id!, title: 't', createdAt: DateTime.now()));

    expect(await mastery.currentStatus(tid), MasteryStatus.unknown);
    await mastery.log(tid, MasteryStatus.learning);
    await mastery.log(tid, MasteryStatus.mastered);
    expect(await mastery.currentStatus(tid), MasteryStatus.mastered);
    expect(await mastery.timeline(tid), hasLength(2));
  });

  test('TopicDomainRepository 增查', () async {
    final subjects = SubjectRepository(sdb);
    final domains = TopicDomainRepository(sdb);
    final math = await subjects.ensureCreate('数学');
    await domains.insert(TopicDomain(subjectId: math.id!, name: '代数', createdAt: DateTime.now()));
    expect(await domains.queryBySubject(math.id!), hasLength(1));
  });
```

- [ ] **Step 5: 运行测试，验证失败**

Run: `cd packages/study_engine && flutter test test/repos_test.dart`
Expected: FAIL（新 Repository 未导出时新用例报错）。

- [ ] **Step 6: 运行测试，验证通过**

Run: `cd packages/study_engine && flutter test test/repos_test.dart`
Expected: PASS（全部用例）。

- [ ] **Step 7: Commit**

```bash
git add packages/study_engine
git commit -m "feat(engine): Mastery + TopicDomain Repository"
```

---

## Task 5: Repository 第三批（LlmConfig + AgentMemory + Chat）

**Files:**
- Create: `packages/study_engine/lib/src/repos/llm_config_repository.dart`
- Create: `packages/study_engine/lib/src/repos/agent_memory_repository.dart`
- Create: `packages/study_engine/lib/src/repos/chat_repository.dart`
- Modify: `packages/study_engine/test/repos_test.dart`（追加用例）
- Modify: `packages/study_engine/lib/study_engine.dart`

**Interfaces:**
- Consumes: `StudyDatabase`、`LlmConfig`/`AgentMemory`/`ChatSession`/`ChatMessage`。
- Produces:
  - `LlmConfigRepository`: `Future<int> insert(LlmConfig c)`、`Future<LlmConfig?> getDefault({bool vision = false})`、`Future<List<LlmConfig>> all()`
  - `AgentMemoryRepository`: `Future<int> add(String scenarioId, String content)`、`Future<List<AgentMemory>> queryByScenario(String scenarioId)`、`Future<List<AgentMemory>> all()`、`Future<void> update(int id, String content)`、`Future<void> delete(int id)`
  - `ChatRepository`: `Future<int> createSession(String scenarioId, String title)`、`Future<int> addMessage(int sessionId, ChatMessage m)`

> 注：`patchMemory` 的"按编号定位"逻辑（`[N]` 编号）放在 AgentScenario 层（Task 10），Repository 只提供按 id 的增删改查。

- [ ] **Step 1: 写 LlmConfigRepository**

Create `packages/study_engine/lib/src/repos/llm_config_repository.dart`：
```dart
import '../db/database.dart';
import '../models/models.dart';

class LlmConfigRepository {
  final StudyDatabase _db;
  LlmConfigRepository(this._db);

  Future<int> insert(LlmConfig c) => _db.db.insert('llm_config', c.toMap());

  Future<List<LlmConfig>> all() async {
    final rows = await _db.db.query('llm_config', orderBy: 'sort_order');
    return rows.map(LlmConfig.fromMap).toList();
  }

  /// 默认配置。vision=true 时优先返回 supports_vision 的默认项。
  Future<LlmConfig?> getDefault({bool vision = false}) async {
    if (vision) {
      final rows = await _db.db.query(
        'llm_config',
        where: 'is_default = 1 AND supports_vision = 1',
        whereArgs: [],
        orderBy: 'sort_order',
        limit: 1,
      );
      if (rows.isNotEmpty) return LlmConfig.fromMap(rows.first);
    }
    final rows = await _db.db.query('llm_config', where: 'is_default = 1', orderBy: 'sort_order', limit: 1);
    return rows.isEmpty ? null : LlmConfig.fromMap(rows.first);
  }
}
```

- [ ] **Step 2: 写 AgentMemoryRepository**

Create `packages/study_engine/lib/src/repos/agent_memory_repository.dart`：
```dart
import 'dart:convert';
import '../db/database.dart';
import '../models/models.dart';

class AgentMemoryRepository {
  final StudyDatabase _db;
  AgentMemoryRepository(this._db);

  Future<int> add(String scenarioId, String content) =>
      _db.db.insert('agent_memory', AgentMemory(scenarioId: scenarioId, content: content, createdAt: DateTime.now()).toMap());

  Future<List<AgentMemory>> queryByScenario(String scenarioId) async {
    final rows = await _db.db.query('agent_memory', where: 'scenario_id = ?', whereArgs: [scenarioId], orderBy: 'created_at ASC');
    return rows.map(AgentMemory.fromMap).toList();
  }

  Future<List<AgentMemory>> all() async {
    final rows = await _db.db.query('agent_memory', orderBy: 'created_at ASC');
    return rows.map(AgentMemory.fromMap).toList();
  }

  Future<void> update(int id, String content) =>
      _db.db.update('agent_memory', {'content': content}, where: 'id = ?', whereArgs: [id]);

  Future<void> delete(int id) =>
      _db.db.delete('agent_memory', where: 'id = ?', whereArgs: [id]);
}
```

- [ ] **Step 3: 写 ChatRepository**

Create `packages/study_engine/lib/src/repos/chat_repository.dart`：
```dart
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
```

- [ ] **Step 4: 追加 barrel 导出**

Modify `packages/study_engine/lib/study_engine.dart`，追加：
```dart
export 'src/repos/llm_config_repository.dart';
export 'src/repos/agent_memory_repository.dart';
export 'src/repos/chat_repository.dart';
```

- [ ] **Step 5: 写失败测试（追加到 repos_test.dart）**

```dart
  test('LlmConfigRepository.getDefault 视觉优先', () async {
    final repo = LlmConfigRepository(sdb);
    await repo.insert(LlmConfig(name: 'text', apiUrl: 'u', apiKey: 'k', model: 'm', isDefault: true, createdAt: DateTime.now()));
    await repo.insert(LlmConfig(name: 'vision', apiUrl: 'u', apiKey: 'k', model: 'mv', supportsVision: true, isDefault: true, createdAt: DateTime.now()));
    final d = await repo.getDefault(vision: true);
    expect(d?.supportsVision, isTrue);
    final plain = await repo.getDefault();
    expect(plain, isNotNull);
  });

  test('AgentMemoryRepository 增删改查', () async {
    final repo = AgentMemoryRepository(sdb);
    final id = await repo.add('study', '经验1');
    expect(await repo.queryByScenario('study'), hasLength(1));
    await repo.update(id, '经验1改');
    expect((await repo.queryByScenario('study')).first.content, '经验1改');
    await repo.delete(id);
    expect(await repo.queryByScenario('study'), isEmpty);
  });

  test('ChatRepository 建会话+存消息', () async {
    final repo = ChatRepository(sdb);
    final sid = await repo.createSession('study', '测试会话');
    await repo.addMessage(sid, const ChatMessage(role: 'user', content: '你好'));
    final rows = await sdb.db.query('chat_message', where: 'session_id = ?', whereArgs: [sid]);
    expect(rows, hasLength(1));
  });
```

- [ ] **Step 6: 运行测试，验证失败**

Run: `cd packages/study_engine && flutter test test/repos_test.dart`
Expected: FAIL（新 Repository 未导出时新用例报错）。

- [ ] **Step 7: 运行测试，验证通过**

Run: `cd packages/study_engine && flutter test test/repos_test.dart`
Expected: PASS（全部用例）。

- [ ] **Step 8: Commit**

```bash
git add packages/study_engine
git commit -m "feat(engine): LlmConfig + AgentMemory + Chat Repository"
```

---

## Task 6: LLM Provider —— DTO（已在 Task 1 含 ChatMessage/ToolCall）与 vision 序列化收尾

`ChatMessage`/`ToolCall`/`ContentPart` 已在 Task 1 完成。本任务补全 LLM 配置 DTO 文件与 barrel 组织，并把 LLM 层的 barrel 建好，为 Task 7/8 铺路。

**Files:**
- Create: `packages/study_engine/lib/src/llm/llm_provider.dart`（LLM 层 barrel）
- Modify: `packages/study_engine/lib/study_engine.dart`
- Test: `packages/study_engine/test/llm_config_test.dart`

**Interfaces:**
- Consumes: Task 1 的 `ChatMessage`。
- Produces: `llm/llm_provider.dart` barrel（暂仅 re-export models 中的 LLM 相关类型）。

- [ ] **Step 1: 写 LLM 层 barrel**

Create `packages/study_engine/lib/src/llm/llm_provider.dart`：
```dart
/// LLM Provider 层 barrel。
/// DTO（ChatMessage/ToolCall/ContentPart/LlmConfig）定义在 models.dart，此处 re-export 便于聚合导入。
library;

export '../models/models.dart' show ChatMessage, ToolCall, ContentPart, TextPart, ImageUrlPart, LlmConfig;
```

- [ ] **Step 2: 追加 barrel 导出**

Modify `packages/study_engine/lib/study_engine.dart`，追加：
```dart
export 'src/llm/llm_provider.dart';
```

- [ ] **Step 3: 写测试（vision 序列化验收）**

Create `packages/study_engine/test/llm_config_test.dart`：
```dart
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
```

- [ ] **Step 4: 运行测试，验证通过**

Run: `cd packages/study_engine && flutter test test/llm_config_test.dart`
Expected: PASS。

- [ ] **Step 5: Commit**

```bash
git add packages/study_engine
git commit -m "feat(engine): LLM Provider 层 barrel + vision 序列化验收"
```

---

## Task 7: LLM Provider —— HTTP 客户端 + SSE 解析

`IoLlmHttpClient` 用 `dart:io` 发请求，可注入便于 mock；`SseToolCallAggregator` 把流式 `delta.tool_calls` 按 index 聚合成完整 `ToolCall`。

**Files:**
- Create: `packages/study_engine/lib/src/llm/llm_provider_client.dart`
- Create: `packages/study_engine/lib/src/llm/llm_provider_sse.dart`
- Create: `packages/study_engine/test/sse_test.dart`
- Modify: `packages/study_engine/lib/src/llm/llm_provider.dart`

**Interfaces:**
- Consumes: `ChatMessage`/`ToolCall`、`LlmConfig`。
- Produces:
  - `LlmHttpClient`（抽象）：`Stream<String> postStream(Uri uri, Map<String,String> headers, Map<String,Object?> body)` —— 逐行产出 SSE data 行
  - `IoLlmHttpClient implements LlmHttpClient`（`dart:io` 实现）
  - `SseToolCallAggregator`：`void onDelta(List? deltaToolCalls)`、`List<ToolCall> result`、`final bool hasToolCalls`

- [ ] **Step 1: 写 HTTP 客户端抽象 + dart:io 实现**

Create `packages/study_engine/lib/src/llm/llm_provider_client.dart`：
```dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// LLM HTTP 客户端抽象，便于测试注入 mock。
abstract class LlmHttpClient {
  /// POST 并逐行产出 SSE 的 data: 行（已去掉 "data: " 前缀，空行与 [DONE] 过滤）。
  Stream<String> postStream(Uri uri, Map<String, String> headers, Map<String, Object?> body);
}

/// 基于 dart:io 的实现。生产与测试共用同一接口。
class IoLlmHttpClient implements LlmHttpClient {
  final HttpClient _http;
  IoLlmHttpClient([HttpClient? http]) : _http = http ?? HttpClient();

  @override
  Stream<String> postStream(Uri uri, Map<String, String> headers, Map<String, Object?> body) async* {
    final req = await _http.postUrl(uri);
    headers.forEach((k, v) => req.headers.set(k, v));
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode(body));
    final resp = await req.close();
    if (resp.statusCode != 200) {
      final sink = StringBuffer();
      await for (final c in resp.transform(utf8.decoder)) {
        sink.write(c);
      }
      throw LlmHttpException(resp.statusCode, sink.toString());
    }
    await for (final rawLine in resp.transform(utf8.decoder).transform(const LineSplitter())) {
      if (!rawLine.startsWith('data:')) continue;
      final data = rawLine.substring(5).trim();
      if (data.isEmpty || data == '[DONE]') continue;
      yield data;
    }
  }
}

class LlmHttpException implements Exception {
  final int statusCode;
  final String body;
  const LlmHttpException(this.statusCode, this.body);
  @override
  String toString() => 'LlmHttpException($statusCode): $body';
}
```

- [ ] **Step 2: 写 SSE tool_calls 聚合器**

Create `packages/study_engine/lib/src/llm/llm_provider_sse.dart`：
```dart
import '../models/models.dart';

/// 把流式响应中的 delta.tool_calls 按 index 聚合成完整 ToolCall。
class SseToolCallAggregator {
  final Map<int, _Partial> _partials = {};
  final StringBuffer _text = StringBuffer();

  bool get hasToolCalls => _partials.isNotEmpty;
  String get text => _text.toString();

  /// 处理一个 SSE chunk 的 JSON 解析结果。
  void onChunk(Map<String, dynamic> chunk) {
    final choices = chunk['choices'] as List?;
    if (choices == null || choices.isEmpty) return;
    final delta = (choices.first as Map<String, dynamic>)['delta'] as Map<String, dynamic>?;
    if (delta == null) return;
    final content = delta['content'];
    if (content is String && content.isNotEmpty) _text.write(content);
    final toolCalls = delta['tool_calls'];
    if (toolCalls is List) {
      for (final tc in toolCalls) {
        if (tc is! Map) continue;
        final index = tc['index'] as int? ?? 0;
        final p = _partials.putIfAbsent(index, () => _Partial());
        final fn = tc['function'] as Map<String, dynamic>?;
        if (fn != null) {
          if (fn['name'] is String) p.name = (p.name ?? '') + fn['name'] as String;
          if (fn['arguments'] is String) p.args = (p.args ?? '') + fn['arguments'] as String;
        }
        if (tc['id'] is String) p.id = tc['id'];
      }
    }
  }

  List<ToolCall> get result {
    final keys = _partials.keys.toList()..sort();
    return keys.map((k) {
      final p = _partials[k]!;
      return ToolCall(id: p.id ?? 'call_$k', name: p.name ?? '', arguments: p.args ?? '{}');
    }).toList();
  }
}

class _Partial {
  String? id;
  String? name;
  String? args;
}
```

- [ ] **Step 3: 追加 LLM 层导出**

Modify `packages/study_engine/lib/src/llm/llm_provider.dart`，追加：
```dart
export 'llm_provider_client.dart';
export 'llm_provider_sse.dart';
```

- [ ] **Step 4: 写失败测试（聚合器单元测试，无需网络）**

Create `packages/study_engine/test/sse_test.dart`：
```dart
import 'package:test/test.dart';
import 'package:study_engine/study_engine.dart';

void main() {
  test('聚合分片 tool_calls delta', () {
    final agg = SseToolCallAggregator();
    agg.onChunk({'choices': [{'delta': {'content': '你好'}}]});
    agg.onChunk({'choices': [{'delta': {'tool_calls': [
      {'index': 0, 'id': 'call_a', 'function': {'name': 'save_top', 'arguments': '{"ti'}},
    ]}}]});
    agg.onChunk({'choices': [{'delta': {'tool_calls': [
      {'index': 0, 'function': {'arguments': 'tle":"t"}'}},
    ]}}]});
    agg.onChunk({'choices': [{'delta': {}}]});
    expect(agg.text, '你好');
    expect(agg.hasToolCalls, isTrue);
    expect(agg.result, hasLength(1));
    final tc = agg.result.first;
    expect(tc.name, 'save_topic');
    expect(tc.arguments, '{"title":"t"}');
    expect(tc.id, 'call_a');
  });

  test('纯文本无工具调用', () {
    final agg = SseToolCallAggregator();
    agg.onChunk({'choices': [{'delta': {'content': '完成'}}]});
    expect(agg.hasToolCalls, isFalse);
    expect(agg.text, '完成');
  });
}
```

- [ ] **Step 5: 运行测试，验证失败**

Run: `cd packages/study_engine && flutter test test/sse_test.dart`
Expected: FAIL（聚合器未导出时报错）。

- [ ] **Step 6: 运行测试，验证通过**

Run: `cd packages/study_engine && flutter test test/sse_test.dart`
Expected: PASS。

- [ ] **Step 7: Commit**

```bash
git add packages/study_engine
git commit -m "feat(engine): LLM HTTP 客户端 + SSE tool_calls 聚合器"
```

---

## Task 8: LLM Provider —— Core（chatStreamWithTools 门面）

把配置 + 客户端 + 聚合器串成 `LlmProvider`，提供 agent loop 调用的流式接口，并把文本 delta 作为事件吐出。

**Files:**
- Create: `packages/study_engine/lib/src/llm/llm_provider_core.dart`
- Modify: `packages/study_engine/lib/src/llm/llm_provider.dart`
- Test: `packages/study_engine/test/llm_core_test.dart`

**Interfaces:**
- Consumes: `LlmConfig`、`LlmHttpClient`、`SseToolCallAggregator`、`ChatMessage`、`ToolCall`。
- Produces:
  - `LlmStreamChunk`（`final String textDelta; final List<ToolCall>? toolCalls;`，末包带聚合结果）
  - `LlmProvider`：`LlmProvider({required LlmConfig config, LlmHttpClient? client})`、`Stream<LlmStreamChunk> chatStreamWithTools({required List<ChatMessage> messages, required List<Map<String,dynamic>> tools})`

- [ ] **Step 1: 写 Core 门面**

Create `packages/study_engine/lib/src/llm/llm_provider_core.dart`：
```dart
import 'dart:convert';
import '../models/models.dart';
import 'llm_provider_client.dart';
import 'llm_provider_sse.dart';

class LlmStreamChunk {
  final String textDelta;
  final List<ToolCall>? toolCalls; // 仅在流结束时（末包）非空
  const LlmStreamChunk({required this.textDelta, this.toolCalls});
}

/// OpenAI 兼容流式 LLM 调用门面。
class LlmProvider {
  final LlmConfig config;
  final LlmHttpClient _client;
  LlmProvider({required this.config, LlmHttpClient? client})
      : _client = client ?? IoLlmHttpClient();

  /// 流式对话（支持工具）。每个文本片段吐一个 chunk（toolCalls 为 null），
  /// 流结束前吐一个末包：textDelta 为空、toolCalls 为聚合结果（可能为空列表表示无工具调用）。
  Stream<LlmStreamChunk> chatStreamWithTools({
    required List<ChatMessage> messages,
    required List<Map<String, dynamic>> tools,
  }) async* {
    final uri = Uri.parse('${config.apiUrl.replaceAll(RegExp(r'/+$'), '')}/chat/completions');
    final body = <String, Object?>{
      'model': config.model,
      'messages': messages.map((m) => m.toJson()).toList(),
      'stream': true,
      if (tools.isNotEmpty) 'tools': tools,
      if (tools.isNotEmpty) 'tool_choice': 'auto',
    };
    final headers = {'Authorization': 'Bearer ${config.apiKey}'};
    final agg = SseToolCallAggregator();
    await for (final data in _client.postStream(uri, headers, body)) {
      final chunk = jsonDecode(data) as Map<String, dynamic>;
      agg.onChunk(chunk);
      final delta = ((chunk['choices'] as List).first as Map)['delta'];
      final content = delta['content'];
      if (content is String && content.isNotEmpty) {
        yield LlmStreamChunk(textDelta: content);
      }
    }
    // 末包
    yield LlmStreamChunk(textDelta: '', toolCalls: agg.result);
  }
}
```

- [ ] **Step 2: 追加导出**

Modify `packages/study_engine/lib/src/llm/llm_provider.dart`，追加：
```dart
export 'llm_provider_core.dart';
```

- [ ] **Step 3: 写测试（用假 SSE 流驱动）**

Create `packages/study_engine/test/llm_core_test.dart`：
```dart
import 'dart:async';
import 'package:test/test.dart';
import 'package:study_engine/study_engine.dart';

/// 假客户端：吐预设的 SSE data 行。
class _FakeClient implements LlmHttpClient {
  _FakeClient(this.lines);
  final List<String> lines;
  @override
  Stream<String> postStream(Uri uri, Map<String, String> headers, Map<String, Object?> body) {
    return Stream.fromIterable(lines);
  }
}

void main() {
  test('chatStreamWithTools 推文本增量并在末包给工具调用', () async {
    final cfg = LlmConfig(
      name: 't', apiUrl: 'https://api.example.com/v1', apiKey: 'k', model: 'm', createdAt: DateTime.now());
    final lines = [
      '{"choices":[{"delta":{"content":"已"}}]}',
      '{"choices":[{"delta":{"content":"保存"}}]}',
      '{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"save_topic","arguments":"{}"}}]}}]}',
    ];
    final provider = LlmProvider(config: cfg, client: _FakeClient(lines));
    final chunks = await provider.chatStreamWithTools(messages: [], tools: []).toList();
    final texts = chunks.where((c) => c.toolCalls == null).map((c) => c.textDelta).join();
    expect(texts, '已保存');
    final endChunk = chunks.lastWhere((c) => c.toolCalls != null);
    expect(endChunk.toolCalls!.first.name, 'save_topic');
  });
}
```

- [ ] **Step 4: 运行测试，验证失败**

Run: `cd packages/study_engine && flutter test test/llm_core_test.dart`
Expected: FAIL（未导出时报错）。

- [ ] **Step 5: 运行测试，验证通过**

Run: `cd packages/study_engine && flutter test test/llm_core_test.dart`
Expected: PASS。

- [ ] **Step 6: Commit**

```bash
git add packages/study_engine
git commit -m "feat(engine): LLM Provider Core（chatStreamWithTools 流式门面）"
```

---

## Task 9: Agent 基础（事件 + Scenario 接口 + 上下文压缩）

**Files:**
- Create: `packages/study_engine/lib/src/agent/agent_event.dart`
- Create: `packages/study_engine/lib/src/agent/agent_scenario.dart`
- Create: `packages/study_engine/lib/src/agent/context_compactor.dart`
- Modify: `packages/study_engine/lib/study_engine.dart`
- Test: `packages/study_engine/test/agent_base_test.dart`

**Interfaces:**
- Consumes: `ChatMessage`、`ToolCall`。
- Produces: 全部 `AgentEvent` 子类；`AgentScenarioContext`、`MemoryPatchResult`、`AgentScenario`（抽象）；`ContextCompactor`。

- [ ] **Step 1: 写事件 sealed class**

Create `packages/study_engine/lib/src/agent/agent_event.dart`：
```dart
/// Agent 运行时事件流。UI 通过 Riverpod StreamProvider 订阅。
sealed class AgentEvent {}

class AgentStartedEvent extends AgentEvent {}

class TextDeltaEvent extends AgentEvent {
  final String delta;
  TextDeltaEvent(this.delta);
}

class ToolCallStartEvent extends AgentEvent {
  final String name;
  final String toolCallId;
  ToolCallStartEvent(this.name, this.toolCallId);
}

class ToolCallEndEvent extends AgentEvent {
  final String name;
  final String result;
  final String toolCallId;
  ToolCallEndEvent(this.name, this.result, this.toolCallId);
}

class ToolProgressEvent extends AgentEvent {
  final String progress;
  ToolProgressEvent(this.progress);
}

class CompactionEvent extends AgentEvent {}

class RetryEvent extends AgentEvent {
  final int attempt;
  RetryEvent(this.attempt);
}

class AgentDoneEvent extends AgentEvent {
  final String? finalText;
  AgentDoneEvent(this.finalText);
}

class AgentErrorEvent extends AgentEvent {
  final String message;
  AgentErrorEvent(this.message);
}
```

- [ ] **Step 2: 写 Scenario 抽象**

Create `packages/study_engine/lib/src/agent/agent_scenario.dart`：
```dart
import '../models/models.dart';

/// 场景上下文：注入每轮动态信息（当前学科、最近拍题结果等）。
class AgentScenarioContext {
  final String? currentSubject;
  final Map<String, Object?> extra;
  const AgentScenarioContext({this.currentSubject, this.extra = const {}});
}

/// patch_memory 工具的结果。
class MemoryPatchResult {
  final bool ok;
  final String message; // 成功提示或编号越界时的可用编号列表
  MemoryPatchResult(this.ok, this.message);
}

/// Agent 场景抽象：每个场景自带工具集、系统提示词、工具执行、记忆。
abstract class AgentScenario {
  String get id;
  String get displayName;
  List<Map<String, dynamic>> get tools;
  String buildSystemPrompt(AgentScenarioContext ctx);

  /// 执行工具，返回给 LLM 的文本结果。
  Future<String> executeTool(
    String name,
    Map<String, dynamic> args, {
    void Function(String)? onProgress,
    String? toolCallId,
  });

  /// 无工具调用时的钩子；返回非 null 则作为额外提示再走一轮。
  Future<String?> onNoToolCalls(List<ChatMessage> messages);

  Future<List<String>> getMemories();
  Future<MemoryPatchResult> patchMemory(int? index, String newText);
  Future<void> cleanup();
}
```

- [ ] **Step 3: 写上下文压缩**

Create `packages/study_engine/lib/src/agent/context_compactor.dart`：
```dart
import '../models/models.dart';

/// 上下文压缩：消息超过阈值时，保留首条 system + 最近 N 轮，其余丢弃。
/// （后续可替换为 LLM 摘要；地基阶段用简单裁剪。）
class ContextCompactor {
  final int threshold; // 消息条数阈值
  final int keepRecent; // 保留最近几条
  const ContextCompactor({this.threshold = 40, this.keepRecent = 20});

  bool needsCompaction(List<ChatMessage> messages) => messages.length > threshold;

  List<ChatMessage> compact(List<ChatMessage> messages) {
    if (!needsCompaction(messages)) return messages;
    final first = messages.firstWhere((m) => m.role == 'system', orElse: () => messages.first);
    final tail = messages.length > keepRecent ? messages.sublist(messages.length - keepRecent) : messages;
    return [first, ...tail.where((m) => m != first)];
  }
}
```

- [ ] **Step 4: 追加 barrel 导出**

Modify `packages/study_engine/lib/study_engine.dart`，追加：
```dart
export 'src/agent/agent_event.dart';
export 'src/agent/agent_scenario.dart';
export 'src/agent/context_compactor.dart';
```

- [ ] **Step 5: 写测试（压缩器）**

Create `packages/study_engine/test/agent_base_test.dart`：
```dart
import 'package:test/test.dart';
import 'package:study_engine/study_engine.dart';

void main() {
  test('超过阈值时裁剪并保留 system + 最近 N 条', () {
    final c = const ContextCompactor(threshold: 5, keepRecent: 2);
    final msgs = <ChatMessage>[
      const ChatMessage(role: 'system', content: 'sys'),
      for (var i = 0; i < 6; i++) ChatMessage(role: 'user', content: 'u$i'),
    ];
    final out = c.compact(msgs);
    expect(out.first.role, 'system');
    expect(out.length, lessThanOrEqualTo(msgs.length));
    expect(out.any((m) => (m.content as String) == 'u5'), isTrue);
  });

  test('未超阈值不裁剪', () {
    final c = const ContextCompactor(threshold: 100);
    final msgs = [const ChatMessage(role: 'user', content: 'x')];
    expect(c.compact(msgs), same(msgs));
  });
}
```

- [ ] **Step 6: 运行测试，验证通过**

Run: `cd packages/study_engine && flutter test test/agent_base_test.dart`
Expected: PASS。

- [ ] **Step 7: Commit**

```bash
git add packages/study_engine
git commit -m "feat(engine): Agent 事件流 + Scenario 抽象 + 上下文压缩"
```

---

## Task 10: Agent 工具 schema + AgentLoop（ReAct 循环）

**Files:**
- Create: `packages/study_engine/lib/src/agent/agent_tools.dart`
- Create: `packages/study_engine/lib/src/agent/agent_loop.dart`
- Modify: `packages/study_engine/lib/study_engine.dart`
- Test: `packages/study_engine/test/agent_loop_test.dart`

**Interfaces:**
- Consumes: `LlmProvider`（Task 8）、`AgentScenario`（Task 9）、`ContextCompactor`、事件类。
- Produces:
  - `AgentTools.studyTools`：`save_topic`、`query_topics` 的 function calling schema（常量列表）
  - `AgentLoop`：`AgentLoop({required LlmProvider llm, required AgentScenario scenario, ContextCompactor? compactor, int maxRounds = 50, int networkRetryPerRound = 2})`、`Stream<AgentEvent> run(List<ChatMessage> messages, {AgentScenarioContext? context})`

- [ ] **Step 1: 写工具 schema**

Create `packages/study_engine/lib/src/agent/agent_tools.dart`：
```dart
/// Agent 工具 schema（OpenAI function calling）。地基阶段 2 个工具。
class AgentTools {
  AgentTools._();

  static const saveTopic = {
    'type': 'function',
    'function': {
      'name': 'save_topic',
      'description': '保存一个知识点到知识库。若指定学科不存在会自动创建。'
          '用于在分析题目或讲解后，把涉及的知识点入库。',
      'parameters': {
        'type': 'object',
        'properties': {
          'subject': {'type': 'string', 'description': '学科名，如“数学”“物理”'},
          'title': {'type': 'string', 'description': '知识点标题'},
          'domain': {'type': 'string', 'description': '学科内领域，如“代数”，可省略'},
          'summary': {'type': 'string', 'description': '知识点摘要，可省略'},
        },
        'required': ['subject', 'title'],
      },
    },
  };

  static const queryTopics = {
    'type': 'function',
    'function': {
      'name': 'query_topics',
      'description': '查询知识库中已保存的知识点列表，可按学科和领域过滤。',
      'parameters': {
        'type': 'object',
        'properties': {
          'subject': {'type': 'string', 'description': '学科名'},
          'domain': {'type': 'string', 'description': '领域，可省略'},
        },
        'required': ['subject'],
      },
    },
  };

  static const studyTools = [saveTopic, queryTopics];
}
```

- [ ] **Step 2: 写 AgentLoop**

Create `packages/study_engine/lib/src/agent/agent_loop.dart`：
```dart
import 'dart:convert';
import '../llm/llm_provider_core.dart';
import '../models/models.dart';
import 'agent_event.dart';
import 'agent_scenario.dart';
import 'context_compactor.dart';

/// ReAct 循环：流式调 LLM → 聚合工具调用 → 执行 → 观察结果 → 进入下一轮。
/// 事件实时 yield（用纯 async*，确保流式增量立即吐出）。
class AgentLoop {
  final LlmProvider llm;
  final AgentScenario scenario;
  final ContextCompactor compactor;
  final int maxRounds;

  AgentLoop({
    required this.llm,
    required this.scenario,
    ContextCompactor? compactor,
    this.maxRounds = 50,
  }) : compactor = compactor ?? const ContextCompactor();

  /// 运行 agent。messages 为初始消息（含 system）。返回实时事件流。
  Stream<AgentEvent> run(List<ChatMessage> messages, {AgentScenarioContext? context}) async* {
    yield AgentStartedEvent();
    final msgs = [...messages];
    var round = 0;
    try {
      while (round < maxRounds) {
        final agg = <ToolCall>[];
        final buf = StringBuffer();
        await for (final chunk in llm.chatStreamWithTools(messages: msgs, tools: scenario.tools)) {
          if (chunk.textDelta.isNotEmpty) {
            buf.write(chunk.textDelta);
            yield TextDeltaEvent(chunk.textDelta); // 实时推送增量
          }
          if (chunk.toolCalls != null) agg.addAll(chunk.toolCalls!);
        }

        if (agg.isEmpty) {
          final inject = await scenario.onNoToolCalls(msgs);
          if (inject != null) {
            msgs.add(ChatMessage(role: 'user', content: inject));
            round++;
            continue;
          }
          yield AgentDoneEvent(buf.toString());
          return;
        }

        // assistant 消息携带 tool_calls
        msgs.add(ChatMessage(role: 'assistant', content: buf.toString(), toolCalls: agg));
        for (final tc in agg) {
          yield ToolCallStartEvent(tc.name, tc.id);
          final args = _parseArgs(tc.arguments);
          String result;
          try {
            result = await scenario.executeTool(tc.name, args, toolCallId: tc.id);
          } catch (e) {
            result = '工具执行出错: $e';
          }
          yield ToolCallEndEvent(tc.name, result, tc.id);
          msgs.add(ChatMessage(role: 'tool', content: result, toolCallId: tc.id));
        }

        if (compactor.needsCompaction(msgs)) {
          final compacted = compactor.compact(msgs);
          msgs
            ..clear()
            ..addAll(compacted);
          yield CompactionEvent();
        }
        round++;
        if (round >= maxRounds) {
          yield AgentDoneEvent(null);
          return;
        }
      }
    } catch (e) {
      yield AgentErrorEvent(e.toString());
    }
  }

  Map<String, dynamic> _parseArgs(String raw) {
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : {};
    } catch (_) {
      return {};
    }
  }
}
```

- [ ] **Step 3: 追加 barrel 导出**

Modify `packages/study_engine/lib/study_engine.dart`，追加：
```dart
export 'src/agent/agent_tools.dart';
export 'src/agent/agent_loop.dart';
```

- [ ] **Step 4: 写测试（用假 LLM + 假 Scenario 验证循环走完一轮工具调用）**

Create `packages/study_engine/test/agent_loop_test.dart`：
```dart
import 'package:test/test.dart';
import 'package:study_engine/study_engine.dart';

/// 假 LLM：用脚本驱动多轮响应。
class _FakeLlm extends LlmProvider {
  _FakeLlm(this.script) : super(config: LlmConfig(
        name: '', apiUrl: '', apiKey: '', model: '', createdAt: DateTime(2026)));
  final List<List<LlmStreamChunk>> script;
  int _i = 0;
  @override
  Stream<LlmStreamChunk> chatStreamWithTools({
    required List<ChatMessage> messages,
    required List<Map<String, dynamic>> tools,
  }) {
    final chunks = _i < script.length ? script[_i++] : const [LlmStreamChunk(textDelta: '完成')];
    return Stream.fromIterable(chunks);
  }
}

class _FakeScenario implements AgentScenario {
  final List<String> executed = [];
  @override String get id => 'fake';
  @override String get displayName => 'Fake';
  @override List<Map<String, dynamic>> get tools => AgentTools.studyTools;
  @override String buildSystemPrompt(AgentScenarioContext ctx) => 'sys';
  @override Future<String> executeTool(String name, Map<String, dynamic> args,
      {void Function(String p)? onProgress, String? toolCallId}) async {
    executed.add(name);
    return '{"ok":true}';
  }
  @override Future<String?> onNoToolCalls(List<ChatMessage> messages) async => null;
  @override Future<List<String>> getMemories() async => [];
  @override Future<MemoryPatchResult> patchMemory(int? index, String newText) async => MemoryPatchResult(true, '');
  @override Future<void> cleanup() async {}
}

void main() {
  test('AgentLoop 执行工具后结束', () async {
    final llm = _FakeLlm([
      const [LlmStreamChunk(textDelta: '', toolCalls: [ToolCall(id: 'c1', name: 'query_topics', arguments: '{"subject":"数学"}')])],
      const [LlmStreamChunk(textDelta: '已完成')],
    ]);
    final scenario = _FakeScenario();
    final loop = AgentLoop(llm: llm, scenario: scenario);
    final events = await loop.run([const ChatMessage(role: 'system', content: 'sys')]).toList();
    expect(scenario.executed, ['query_topics']);
    expect(events.any((e) => e is AgentDoneEvent), isTrue);
    expect(events.any((e) => e is ToolCallStartEvent), isTrue);
  });
}
```

- [ ] **Step 5: 运行测试，验证失败**

Run: `cd packages/study_engine && flutter test test/agent_loop_test.dart`
Expected: FAIL（loop 未导出/未实现时报错）。

- [ ] **Step 6: 运行测试，验证通过**

Run: `cd packages/study_engine && flutter test test/agent_loop_test.dart`
Expected: PASS。

- [ ] **Step 7: Commit**

```bash
git add packages/study_engine
git commit -m "feat(engine): Agent 工具 schema + ReAct 循环（AgentLoop）"
```

---

## Task 11: StudyScenario 实现 + Agent 集成测试（save_topic 落库）

把工具 schema、系统提示词、工具执行（调 Repository）、记忆 patch 串成 `StudyScenario`；并写端到端集成测试：mock LLM 返回 save_topic 工具调用，验证知识点真的落库。

**Files:**
- Create: `packages/study_engine/lib/src/agent/scenarios/study_scenario.dart`
- Modify: `packages/study_engine/lib/study_engine.dart`
- Test: `packages/study_engine/test/study_scenario_integration_test.dart`

**Interfaces:**
- Consumes: `AgentScenario`、`AgentTools.studyTools`、`SubjectRepository`、`TopicRepository`、`AgentMemoryRepository`。
- Produces: `StudyScenario implements AgentScenario`。

- [ ] **Step 1: 写 StudyScenario**

Create `packages/study_engine/lib/src/agent/scenarios/study_scenario.dart`：
```dart
import '../../models/models.dart';
import '../../repos/agent_memory_repository.dart';
import '../../repos/subject_repository.dart';
import '../../repos/topic_repository.dart';
import '../agent_scenario.dart';
import '../agent_tools.dart';

/// 学习伴侣场景：tools = save_topic/query_topics，工具执行调 Repository，
/// 记忆来自 agent_memory 表。
class StudyScenario implements AgentScenario {
  final SubjectRepository subjects;
  final TopicRepository topics;
  final AgentMemoryRepository memories;

  StudyScenario({required this.subjects, required this.topics, required this.memories});

  @override String get id => 'study';
  @override String get displayName => '学习伴侣';
  @override List<Map<String, dynamic>> get tools => AgentTools.studyTools;

  @override
  String buildSystemPrompt(AgentScenarioContext ctx) {
    final mem = _memCache;
    final memBlock = mem.isEmpty ? '（暂无）' : mem.asMap().entries.map((e) => '[${e.key + 1}] ${e.value}').join('\n');
    final subjectLine = ctx.currentSubject == null ? '' : '\n当前学科：${ctx.currentSubject}';
    return '''你是学习伴侣 AI。你的职责是帮助用户分析题目、讲解知识点、整理知识库、并跟踪掌握状态。

## 工作原则
- 分析题目后，用 save_topic 把涉及的知识点入库（学科不存在会自动创建）。
- 用 query_topics 查看已有知识点，避免重复入库。
- 简洁、聚焦知识点本身。

## 经验记忆
$memBlock''';
    // subjectLine 可在此处忽略或拼入；保留变量供后续动态注入。
    // ignore: unused_element
    void _unused() => subjectLine;
  }

  List<String> _memCache = const [];

  @override
  Future<String> executeTool(String name, Map<String, dynamic> args,
      {void Function(String p)? onProgress, String? toolCallId}) async {
    switch (name) {
      case 'save_topic':
        final subjectName = args['subject'] as String;
        final title = args['title'] as String;
        final domain = args['domain'] as String?;
        final summary = args['summary'] as String?;
        final subject = await subjects.ensureCreate(subjectName);
        final id = await topics.insert(Topic(
          subjectId: subject.id!,
          domain: domain,
          title: title,
          summary: summary,
          createdAt: DateTime.now(),
        ));
        return '已保存知识点“$title”（id=$id），学科“$subjectName”';
      case 'query_topics':
        final subjectName = args['subject'] as String;
        final domain = args['domain'] as String?;
        final subject = await subjects.findByName(subjectName);
        if (subject == null) return '学科“$subjectName”不存在';
        final list = await topics.queryBySubject(subject.id!, domain: domain);
        if (list.isEmpty) return '没有匹配的知识点';
        return list.map((t) => '- ${t.title}${t.domain == null ? "" : "（${t.domain}）"}').join('\n');
      default:
        return '未知工具: $name';
    }
  }

  @override
  Future<String?> onNoToolCalls(List<ChatMessage> messages) async => null;

  @override
  Future<List<String>> getMemories() async {
    _memCache = (await memories.queryByScenario(id)).map((m) => m.content).toList();
    return _memCache;
  }

  @override
  Future<MemoryPatchResult> patchMemory(int? index, String newText) async {
    final all = await memories.queryByScenario(id);
    if (index == null) {
      await memories.add(id, newText);
      return MemoryPatchResult(true, '已新增记忆');
    }
    final i = index - 1;
    if (i < 0 || i >= all.length) {
      return MemoryPatchResult(false, '编号越界，可用范围 1..${all.length}');
    }
    await memories.update(all[i].id!, newText);
    return MemoryPatchResult(true, '已更新记忆 $index');
  }

  @override
  Future<void> cleanup() async {}
}
```

- [ ] **Step 2: 追加 barrel 导出**

Modify `packages/study_engine/lib/study_engine.dart`，追加：
```dart
export 'src/agent/scenarios/study_scenario.dart';
```

- [ ] **Step 3: 写集成测试（mock LLM → save_topic → 验证落库）**

Create `packages/study_engine/test/study_scenario_integration_test.dart`：
```dart
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';
import 'package:study_engine/study_engine.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test('Agent 调 save_topic 后知识点落库', () async {
    final sdb = await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final subjects = SubjectRepository(sdb);
    final topics = TopicRepository(sdb);
    final memories = AgentMemoryRepository(sdb);
    final scenario = StudyScenario(subjects: subjects, topics: topics, memories: memories);

    // 手动执行一次工具，验证落库（集成测试不依赖真实网络）
    final result = await scenario.executeTool('save_topic', {
      'subject': '物理',
      'title': '牛顿第二定律',
      'domain': '力学',
    });
    expect(result, contains('已保存'));

    final phys = await subjects.findByName('物理');
    expect(phys, isNotNull);
    final list = await topics.queryBySubject(phys!.id!);
    expect(list, hasLength(1));
    expect(list.first.title, '牛顿第二定律');
    expect(list.first.domain, '力学');

    // 通过 AgentLoop 端到端：mock LLM 返回 save_topic
    final llm = _ScriptedLlm([
      const [LlmStreamChunk(textDelta: '', toolCalls: [
        ToolCall(id: 'c1', name: 'save_topic', arguments: '{"subject":"物理","title":"惯性","domain":"力学"}'),
      ]],
      const [LlmStreamChunk(textDelta: '已为你保存知识点')],
    ]);
    final loop = AgentLoop(llm: llm, scenario: scenario);
    final events = await loop.run([const ChatMessage(role: 'system', content: 'sys')]).toList();
    expect(events.any((e) => e is ToolCallEndEvent), isTrue);
    final list2 = await topics.queryBySubject(phys.id!);
    expect(list2.any((t) => t.title == '惯性'), isTrue);

    await sdb.close();
  });
}

class _ScriptedLlm extends LlmProvider {
  _ScriptedLlm(this.script) : super(config: LlmConfig(
        name: '', apiUrl: '', apiKey: '', model: '', createdAt: DateTime(2026)));
  final List<List<LlmStreamChunk>> script;
  int _i = 0;
  @override
  Stream<LlmStreamChunk> chatStreamWithTools({
    required List<ChatMessage> messages,
    required List<Map<String, dynamic>> tools,
  }) {
    final chunks = _i < script.length ? script[_i++] : const [LlmStreamChunk(textDelta: '完成')];
    return Stream.fromIterable(chunks);
  }
}
```

- [ ] **Step 4: 运行测试，验证失败**

Run: `cd packages/study_engine && flutter test test/study_scenario_integration_test.dart`
Expected: FAIL（scenario 未导出时报错）。

- [ ] **Step 5: 运行测试，验证通过**

Run: `cd packages/study_engine && flutter test`
Expected: PASS（全部 engine 测试通过——这是 spec 验收标准 2 的 agent 集成测试）。

- [ ] **Step 6: Commit**

```bash
git add packages/study_engine
git commit -m "feat(engine): StudyScenario + Agent 集成测试（save_topic 落库）"
```

---

## Task 12: 顶层 App 接入（go_router + 占位首页 + Riverpod provider 骨架）

**Files:**
- Modify: `study_buddy/lib/main.dart`（改为 ProviderScope + MaterialApp.router）
- Create: `study_buddy/lib/app.dart`
- Create: `study_buddy/lib/router.dart`
- Create: `study_buddy/lib/core/providers/database_provider.dart`
- Create: `study_buddy/lib/features/home/home_page.dart`
- Test: `study_buddy/test/app_scaffold_test.dart`

**Interfaces:**
- Consumes: `study_engine`（`StudyDatabase`，Windows 用 `databaseFactoryFfi`）、`flutter_riverpod`、`go_router`。
- Produces: 可启动 app：`flutter run -d windows` 显示占位首页，启动时初始化 SQLite。

- [ ] **Step 1: 写 database provider**

Create `study_buddy/lib/core/providers/database_provider.dart`：
```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:study_engine/study_engine.dart';

/// 应用启动时初始化的 SQLite 数据库。
/// Windows 桌面用 sqflite_common_ffi；移动端后续切换 sqflite 默认 factory。
final databaseProvider = FutureProvider<StudyDatabase>((ref) async {
  sqfliteFfiInit();
  final dir = await getApplicationSupportDirectory();
  final path = p.join(dir.path, 'study_buddy.db');
  final sdb = await StudyDatabase.open(factory: databaseFactoryFfi, path: path);
  ref.onDispose(sdb.close);
  return sdb;
});
```

> 注：需在 app pubspec 加 `sqflite_common_ffi` 与 `path_provider`、`sqflite_common`（作为 transitive，显式声明更稳）。在 Step 6 补 pubspec。

- [ ] **Step 2: 写占位首页**

Create `study_buddy/lib/features/home/home_page.dart`：
```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:study_engine/study_engine.dart';
import '../../core/providers/database_provider.dart';

class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dbAsync = ref.watch(databaseProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Study Buddy')),
      body: dbAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('数据库初始化失败: $e')),
        data: (db) => const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              '地基已就绪 ✅\n数据库已连接。\n\n'
              '（业务功能将在后续子项目迭代中加入）',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16),
            ),
          ),
        ),
      ),
    );
  }
}
```

- [ ] **Step 3: 写路由**

Create `study_buddy/lib/router.dart`：
```dart
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'features/home/home_page.dart';

GoRouter buildRouter() {
  return GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => const HomePage(),
      ),
    ],
  );
}
```

- [ ] **Step 4: 写 app.dart + 改造 main.dart**

Create `study_buddy/lib/app.dart`：
```dart
import 'package:flutter/material.dart';
import 'router.dart';

class StudyBuddyApp extends StatelessWidget {
  const StudyBuddyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Study Buddy',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      routerConfig: buildRouter(),
    );
  }
}
```

Modify `study_buddy/lib/main.dart`（整体替换为最简入口）：
```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app.dart';

void main() {
  runApp(const ProviderScope(child: StudyBuddyApp()));
}
```

- [ ] **Step 5: 补 app pubspec 依赖**

Modify `study_buddy/pubspec.yaml`，在 `dependencies:` 追加：
```yaml
  sqflite_common: ^2.5.4
  sqflite_common_ffi: ^2.3.4
  path_provider: ^2.1.5
```
（`study_engine`、`go_router`、`path` 已在 Task 0 加入。）
执行：`cd study_buddy && flutter pub get`。

- [ ] **Step 6: 更新默认 widget 测试**

Replace `study_buddy/test/widget_test.dart` 内容：
```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:study_buddy/app.dart';

void main() {
  testWidgets('app 启动并渲染首页', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: StudyBuddyApp()));
    await tester.pump(); // 触发数据库 FutureProvider
    // 至少应出现 AppBar 标题
    expect(find.text('Study Buddy'), findsOneWidget);
  });
}
```

> 注：该测试在桌面 CI 环境可能因 sqflite_ffi 需要原生库而跳过；本地 `flutter run -d windows` 是主要验收。若 widget test 因 ffi 报错，把它标记为 `@OnPlatform({'windows': Skip()})` 或改为仅断言路由构建。

- [ ] **Step 7: analyze 全包 + app 测试**

Run: `cd packages/study_engine && flutter analyze`
Expected: No issues found.
Run: `cd study_buddy && flutter analyze`
Expected: No issues found.
Run: `cd study_buddy && flutter test`
Expected: PASS（或按注解跳过 ffi 相关）。

- [ ] **Step 8: 启动验证（spec 验收标准 3）**

Run: `cd study_buddy && flutter run -d windows`
Expected: 窗口启动，显示 "Study Buddy" 标题与 "地基已就绪" 文案，不崩溃。手动关闭窗口结束。

- [ ] **Step 9: Commit**

```bash
git add study_buddy
git commit -m "feat(app): 接入 go_router + 占位首页 + SQLite 初始化（地基验收）"
```

---

## 最终验收（对照 spec 第 8 节）

- [ ] **A1**: `cd packages/study_engine && flutter analyze` → No issues found。
- [ ] **A2**: `cd study_buddy && flutter analyze` → No issues found。
- [ ] **B1**: `cd packages/study_engine && flutter test` → 全部通过（含 db_test、repos_test、sse_test、llm_core_test、agent_loop_test、study_scenario_integration_test、models_test、llm_config_test、agent_base_test）。
- [ ] **B2**: `cd study_buddy && flutter test` → 通过。
- [ ] **C**: `cd study_buddy && flutter run -d windows` → 启动显示占位首页，不崩溃。
