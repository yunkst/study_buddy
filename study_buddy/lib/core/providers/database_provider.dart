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
  // 注：sdb.close 返回 Future<void>，而 Ref.onDispose 期望 void Function()，
  // 因此用箭头函数包裹（返回的 Future 被忽略，符合 onDispose 语义）。
  ref.onDispose(() => sdb.close());
  return sdb;
});
