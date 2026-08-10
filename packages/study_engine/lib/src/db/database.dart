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
      ),
    );
    return StudyDatabase._(db);
  }

  Future<void> close() => db.close();
}
