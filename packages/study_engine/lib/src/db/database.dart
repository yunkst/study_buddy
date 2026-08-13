import 'package:sqflite_common/sqlite_api.dart';
import '../logging/logger_sink.dart';
import 'database_migrations.dart';

/// 持有 SQLite 连接的门面。factory 由调用方注入（生产/测试各异）。
class StudyDatabase {
  final Database db;

  /// open 时注入的日志出口（默认 [NullLoggerSink]）。
  ///
  /// 各 repository 通过 `_db.logger` 复用同一出口上报「吞掉/降级」事件
  /// （如 UNIQUE 幂等冲突），避免写操作失败不可观测。普通 insert 异常会上抛
  /// 由上层（agent_loop / provider）记录，不在此重复。
  final LoggerSink logger;

  StudyDatabase._(this.db, this.logger);

  /// 打开/创建数据库。factory 为 null 时由调用环境提供（app 用 sqflite/sqflite_common_ffi）。
  ///
  /// [logger] 可选；注入后 onCreate/onUpgrade/onDowngrade 三条迁移路径都会
  /// 透传到 [migrateDatabase]，使 `migration-start/step/done/failed` 埋点入库，
  /// 并保存到 [logger] 字段供各 repository 复用。
  /// 未传则走 [NullLoggerSink] 兜底，行为与历史一致（向后兼容）。
  static Future<StudyDatabase> open({
    required DatabaseFactory factory,
    required String path,
    LoggerSink? logger,
  }) async {
    final db = await factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: kCurrentDbVersion,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: (db, _) => migrateDatabase(db, 0, kCurrentDbVersion, logger: logger),
        onUpgrade: (db, oldV, newV) => migrateDatabase(db, oldV, newV, logger: logger),
        // 降级（用户回滚到旧版 APK）默认抛异常。本地学习数据跨版本降级无法逐表还原，
        // 销毁重建最安全：清空所有表后按目标版本重建，避免「高版本表 + 低版本号」崩溃。
        // 用闭包捕获 logger，透传到 static onDowngradeRecreate。
        onDowngrade: (db, oldV, newV) async =>
            onDowngradeRecreate(db, oldV, newV, logger: logger),
      ),
    );
    return StudyDatabase._(db, logger ?? const NullLoggerSink());
  }

  Future<void> close() => db.close();

  /// 降级处理：删除所有用户表后，按目标版本从零重建。
  ///
  /// [logger] 可选；生产链路通过 [open] 的 onDowngrade 闭包透传，测试直接调用
  /// 时省略，走 [NullLoggerSink] 兜底。
  static Future<void> onDowngradeRecreate(
    Database db,
    int oldVersion,
    int newVersion, {
    LoggerSink? logger,
  }) async {
    final tables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'android_%'",
    );
    await db.execute('PRAGMA foreign_keys = OFF');
    for (final row in tables) {
      final name = row['name'] as String;
      await db.execute('DROP TABLE IF EXISTS "$name"');
    }
    await db.execute('PRAGMA foreign_keys = ON');
    await migrateDatabase(db, 0, newVersion, logger: logger);
  }
}
