import 'package:sqflite_common/sqlite_api.dart';

import '../logging/logger_sink.dart';

/// 当前数据库版本号。每加一张表/字段 +1。
const int kCurrentDbVersion = 9;

/// 执行迁移：按版本号顺序升级。from==0 表示全新建库。
///
/// [logger] 可选；未注入时使用 [NullLoggerSink] 兜底，保证现有调用点
/// `migrateDatabase(db, from, to)` 编译与行为不变。
Future<void> migrateDatabase(
  Database db,
  int from,
  int to, {
  LoggerSink? logger,
}) async {
  final log = logger ?? const NullLoggerSink();
  final batch = db.batch();
  log.log(
    LoggerLevel.info,
    '数据库迁移开始: v$from → v$to',
    category: 'database',
    tags: const ['migration-start'],
  );
  for (var v = from + 1; v <= to; v++) {
    try {
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
        case 4:
          _v4(batch);
          break;
        case 5:
          _v5(batch);
          break;
        case 6:
          _v6(batch);
          break;
        case 7:
          _v7(batch);
          break;
        case 8:
          _v8(batch);
          break;
        case 9:
          _v9(batch);
          break;
        default:
          throw StateError('未知数据库版本: $v');
      }
      log.log(
        LoggerLevel.debug,
        '数据库迁移步骤 v$v 完成',
        category: 'database',
        tags: const ['migration-step'],
      );
    } catch (e, st) {
      log.log(
        LoggerLevel.error,
        '数据库迁移失败 v$v: $e',
        category: 'database',
        stackTrace: st.toString(),
        tags: const ['migration-failed'],
      );
      rethrow;
    }
  }
  await batch.commit();
  log.log(
    LoggerLevel.info,
    '数据库迁移完成: v$to',
    category: 'database',
    tags: const ['migration-done'],
  );
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
  // mastery_log 引用 topic(id)，先临时移除 FK 约束：重建 mastery_log 不带 FK。
  // topic 重建完成后会在 _v2 末尾再次重建 mastery_log 恢复 FK，见下方。
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

  // topic 已重建完成，恢复 mastery_log 的 FK 约束（v2 开头临时移除了它以便 DROP topic）。
  // 重建带 FK 的 mastery_log，迁移数据，清理临时表。
  batch.execute('CREATE TABLE mastery_log_fk AS SELECT * FROM mastery_log');
  batch.execute('DROP TABLE mastery_log');
  batch.execute('''
    CREATE TABLE mastery_log (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      topic_id INTEGER NOT NULL,
      status TEXT NOT NULL,
      reason TEXT,
      changed_at INTEGER NOT NULL,
      FOREIGN KEY (topic_id) REFERENCES topic(id) ON DELETE CASCADE
    )
  ''');
  batch.execute('INSERT INTO mastery_log SELECT * FROM mastery_log_fk');
  batch.execute('DROP TABLE mastery_log_fk');
  batch.execute('CREATE INDEX IF NOT EXISTS idx_mastery_topic ON mastery_log(topic_id, changed_at)');

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

/// v3：学习计划三表。只增不改既有表。
void _v3(Batch batch) {
  batch.execute('''
    CREATE TABLE plan (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      exam_date INTEGER NOT NULL,
      exam_content TEXT NOT NULL,
      target TEXT NOT NULL,
      daily_minutes INTEGER NOT NULL,
      current_level TEXT,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    )
  ''');
  batch.execute('''
    CREATE TABLE milestone (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      plan_id INTEGER NOT NULL,
      title TEXT NOT NULL,
      description TEXT NOT NULL,
      target_date INTEGER NOT NULL,
      sort_order INTEGER NOT NULL DEFAULT 0,
      status TEXT NOT NULL DEFAULT 'pending',
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      FOREIGN KEY (plan_id) REFERENCES plan(id) ON DELETE CASCADE
    )
  ''');
  batch.execute('CREATE INDEX idx_milestone_plan ON milestone(plan_id)');
  batch.execute('''
    CREATE TABLE assessment (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      plan_id INTEGER NOT NULL,
      score INTEGER,
      note TEXT,
      assessed_at INTEGER NOT NULL,
      created_at INTEGER NOT NULL,
      FOREIGN KEY (plan_id) REFERENCES plan(id) ON DELETE CASCADE
    )
  ''');
  batch.execute('CREATE INDEX idx_assessment_plan ON assessment(plan_id, assessed_at)');
}

/// v4：批改记录表(单表 + items JSON 明细)。只增不改既有表。
void _v4(Batch batch) {
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

/// v5：专注时钟。新增 focus_session（会话）与 focus_session_topic（会话-知识点关联）。
/// 非破坏性：仅加表与索引，不动现有 v1/v2/v3/v4 表。
void _v5(Batch batch) {
  batch.execute('''
    CREATE TABLE focus_session (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      started_at INTEGER NOT NULL,
      ended_at INTEGER,
      duration_ms INTEGER
    )
  ''');
  batch.execute('CREATE INDEX idx_focus_session_started ON focus_session(started_at)');

  batch.execute('''
    CREATE TABLE focus_session_topic (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id INTEGER NOT NULL,
      topic_id INTEGER NOT NULL,
      linked_at INTEGER NOT NULL,
      FOREIGN KEY (session_id) REFERENCES focus_session(id) ON DELETE CASCADE,
      FOREIGN KEY (topic_id) REFERENCES topic(id) ON DELETE CASCADE,
      UNIQUE(session_id, topic_id)
    )
  ''');
  batch.execute('CREATE INDEX idx_fst_session ON focus_session_topic(session_id)');
}

/// v6：知识点 FSRS 间隔重复调度。新增 topic_schedule（每知识点一行 FSRS 状态），
/// 并清空老 mastery_log 历史（表保留，后续继续写新轨迹）。
///
/// - topic_schedule：topic_id 即主键且外键指向 topic(id) ON DELETE CASCADE，
///   随知识点删除自动清理调度状态。
/// - idx_topic_schedule_due：按 due_at 索引，加速「到期复习」查询。
/// - DELETE FROM mastery_log：用户确认清空老掌握度轨迹历史；旧 status 语义
///   与新 FSRS 模型不兼容，保留空表给后续新写。
void _v6(Batch batch) {
  batch.execute('''
    CREATE TABLE topic_schedule (
      topic_id INTEGER PRIMARY KEY,
      stability REAL NOT NULL,
      difficulty REAL NOT NULL,
      reps INTEGER NOT NULL,
      lapses INTEGER NOT NULL,
      last_reviewed_at INTEGER,
      due_at INTEGER,
      FOREIGN KEY (topic_id) REFERENCES topic(id) ON DELETE CASCADE
    )
  ''');
  batch.execute('CREATE INDEX idx_topic_schedule_due ON topic_schedule(due_at)');
  batch.execute('DELETE FROM mastery_log');
}

/// v7：专注会话 summary 列。新增 focus_session.summary TEXT 字段，
/// 用于保存用户停止专注时输入的「这段时间做了什么」备注（App 内停止触发弹框），
/// 通知栏停止不留备注。
///
/// - 非破坏性 ALTER TABLE 老数据该列为 NULL,不需回填。
/// - 不变更其它列、不动 v6 表。
void _v7(Batch batch) {
  batch.execute('ALTER TABLE focus_session ADD COLUMN summary TEXT');
}

/// v8：每日打卡。新增 plan_day_task（任务挂在一个具体本地日历日）。
///
/// - task_date 存「本地零点 unix millis」，归一化在 repo 层做。
/// - ON DELETE CASCADE 跟随 milestone/assessment 习惯。
void _v8(Batch batch) {
  batch.execute('''
    CREATE TABLE plan_day_task (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      plan_id INTEGER NOT NULL,
      task_date INTEGER NOT NULL,
      title TEXT NOT NULL,
      sort_order INTEGER NOT NULL DEFAULT 0,
      status TEXT NOT NULL DEFAULT 'pending',
      done_at INTEGER,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      FOREIGN KEY (plan_id) REFERENCES plan(id) ON DELETE CASCADE,
      CHECK (status IN ('pending', 'done'))
    )
  ''');
  batch.execute(
    'CREATE INDEX idx_plan_day_task_plan_date ON plan_day_task(plan_id, task_date)',
  );
}

/// v9：合并 study/plan 两个 agent 场景为单一 study_plan。
/// agent_memory 与 chat_session 的 scenario_id 一并归并（两列均无 UNIQUE/FK 约束，UPDATE 幂等）。
void _v9(Batch batch) {
  batch.execute(
    "UPDATE agent_memory SET scenario_id = 'study_plan' WHERE scenario_id IN ('study', 'plan')",
  );
  batch.execute(
    "UPDATE chat_session SET scenario_id = 'study_plan' WHERE scenario_id IN ('study', 'plan')",
  );
}
