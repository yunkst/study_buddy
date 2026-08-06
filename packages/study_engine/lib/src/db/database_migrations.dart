import 'package:sqflite_common/sqlite_api.dart';

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
