import 'package:sqflite_common/sqlite_api.dart';

/// 当前数据库版本号。每加一张表/字段 +1。
const int kCurrentDbVersion = 3;

/// 执行迁移：按版本号顺序升级。from==0 表示全新建库。
Future<void> migrateDatabase(Database db, int from, int to) async {
  final batch = db.batch();
  for (var v = from + 1; v <= to; v++) {
    switch (v) {
      case 1:
        _v1(batch);
        break;
      case 2:
        _v2(batch);
        break;
      case 3:
        _v3(batch);
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

/// v2：知识点体系重设计。新建 category 表，重建 topic 表（废弃 domain/subject_id/parent_topic_id，
/// 加 category_id/question/updated_at，title 改 UNIQUE，summary 改 NOT NULL），新建 topic_edge 表。
/// 地基阶段无真实数据，直接 DROP 重建 topic。
void _v2(Batch batch) {
  // 删除依赖 topic 的旧索引（mastery_log 的 idx_mastery_topic 不依赖 topic 字段，保留）
  batch.execute('DROP TABLE IF EXISTS topic_domain');
  // mastery_log 引用 topic(id)，先临时移除 FK 约束：重建 mastery_log 不带 FK
  batch.execute('CREATE TABLE mastery_log_new AS SELECT * FROM mastery_log');
  batch.execute('DROP TABLE mastery_log');
  batch.execute('''
    CREATE TABLE mastery_log (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      topic_id INTEGER NOT NULL,
      status TEXT NOT NULL,
      reason TEXT,
      changed_at INTEGER NOT NULL
    )
  ''');
  batch.execute('INSERT INTO mastery_log SELECT * FROM mastery_log_new');
  batch.execute('DROP TABLE mastery_log_new');
  batch.execute('CREATE INDEX IF NOT EXISTS idx_mastery_topic ON mastery_log(topic_id, changed_at)');

  // 重建 subject 为 category 顶级节点（无真实数据，直接重建）
  batch.execute('DROP TABLE IF EXISTS topic');
  batch.execute('DROP TABLE IF EXISTS subject');

  batch.execute('''
    CREATE TABLE category (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      parent_id INTEGER,
      name TEXT NOT NULL,
      sort_order INTEGER NOT NULL DEFAULT 0,
      created_at INTEGER NOT NULL,
      FOREIGN KEY (parent_id) REFERENCES category(id) ON DELETE RESTRICT
    )
  ''');
  batch.execute('CREATE INDEX idx_category_parent ON category(parent_id)');

  batch.execute('''
    CREATE TABLE topic (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      category_id INTEGER NOT NULL,
      question TEXT NOT NULL,
      title TEXT NOT NULL UNIQUE,
      summary TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      FOREIGN KEY (category_id) REFERENCES category(id)
    )
  ''');
  batch.execute('CREATE INDEX idx_topic_category ON topic(category_id)');

  batch.execute('''
    CREATE TABLE topic_edge (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      from_topic_id INTEGER NOT NULL,
      to_topic_id INTEGER NOT NULL,
      type TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      FOREIGN KEY (from_topic_id) REFERENCES topic(id) ON DELETE CASCADE,
      FOREIGN KEY (to_topic_id) REFERENCES topic(id) ON DELETE CASCADE,
      UNIQUE(from_topic_id, to_topic_id, type)
    )
  ''');
  batch.execute('CREATE INDEX idx_topic_edge_from ON topic_edge(from_topic_id)');
  batch.execute('CREATE INDEX idx_topic_edge_to ON topic_edge(to_topic_id)');
}

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
