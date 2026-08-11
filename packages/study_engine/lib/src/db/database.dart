import 'package:sqflite_common/sqlite_api.dart';
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
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: (db, _) => migrateDatabase(db, 0, kCurrentDbVersion),
        onUpgrade: (db, oldV, newV) => migrateDatabase(db, oldV, newV),
        // 降级（用户回滚到旧版 APK）默认抛异常。本地学习数据跨版本降级无法逐表还原，
        // 销毁重建最安全：清空所有表后按目标版本重建，避免「高版本表 + 低版本号」崩溃。
        onDowngrade: onDowngradeRecreate,
      ),
    );
    return StudyDatabase._(db);
  }

  Future<void> close() => db.close();

  /// 降级处理：删除所有用户表后，按目标版本从零重建。
  static Future<void> onDowngradeRecreate(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    final tables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'android_%'",
    );
    await db.execute('PRAGMA foreign_keys = OFF');
    for (final row in tables) {
      final name = row['name'] as String;
      await db.execute('DROP TABLE IF EXISTS "$name"');
    }
    await db.execute('PRAGMA foreign_keys = ON');
    await migrateDatabase(db, 0, newVersion);
  }
}
