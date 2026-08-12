import 'dart:io' show Platform;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:study_engine/study_engine.dart';

import '../services/logger_service.dart';

/// 应用启动时初始化的 SQLite 数据库。
///
/// 平台分派：
/// - Android/iOS 用原生 sqflite（系统内置 libsqlite3，无需打包 native 库）
/// - 其他平台（Windows/Linux/macOS/桌面）用 sqflite_common_ffi，自带 libsqlite3
///
/// [logger] 透传到 StudyDatabase.open：生产 app 启动迁移走真实 LoggerSink，
/// `migration-start/step/done/failed` 埋点入内存队列（init 完成后 flush）。
/// LoggerService 单例构造无副作用，启动早期未 init 时也安全。
Future<StudyDatabase> _openDb(String path, {LoggerSink? logger}) async {
  if (Platform.isAndroid || Platform.isIOS) {
    return StudyDatabase.open(factory: sqflite.databaseFactory, path: path, logger: logger);
  }
  sqfliteFfiInit();
  return StudyDatabase.open(factory: databaseFactoryFfi, path: path, logger: logger);
}

final databaseProvider = FutureProvider<StudyDatabase>((ref) async {
  final dir = await getApplicationSupportDirectory();
  final path = p.join(dir.path, 'study_buddy.db');
  final sdb = await _openDb(path, logger: LoggerService.instance);
  // 注：sdb.close 返回 Future<void>，而 Ref.onDispose 期望 void Function()，
  // 因此用箭头函数包裹（返回的 Future 被忽略，符合 onDispose 语义）。
  ref.onDispose(() => sdb.close());
  return sdb;
});
