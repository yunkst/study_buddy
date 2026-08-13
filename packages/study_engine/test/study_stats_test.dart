import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';
import 'package:study_engine/study_engine.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  late StudyDatabase sdb;
  late FocusSessionRepository repo;

  setUp(() async {
    sdb = await StudyDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    repo = FocusSessionRepository(sdb);
  });
  tearDown(() async => await sdb.close());

  /// 便捷：插入一段当天 [startedAt] 的专注会话。duration 默认结束。
  Future<void> addSession(DateTime startedAt, {int? durationMs = 1800000}) async {
    final id = await repo.start(startedAt);
    if (durationMs != null) {
      await repo.end(id, startedAt, durationMs);
    }
  }

  group('computeStreak', () {
    final today = DateTime(2026, 8, 13);

    test('无记录 → 0', () async {
      expect(await computeStreak(repo: repo, today: today), 0);
    });

    test('只有今天 → 1', () async {
      await addSession(DateTime(2026, 8, 13, 9, 0));
      expect(await computeStreak(repo: repo, today: today), 1);
    });

    test('只有昨天（今天还没学）→ 1', () async {
      await addSession(DateTime(2026, 8, 12, 9, 0));
      expect(await computeStreak(repo: repo, today: today), 1);
    });

    test('只有前天（今天昨天都没学）→ 0', () async {
      await addSession(DateTime(2026, 8, 11, 9, 0));
      expect(await computeStreak(repo: repo, today: today), 0);
    });

    test('连续 5 天且今天已学 → 5', () async {
      for (var i = 0; i < 5; i++) {
        await addSession(DateTime(2026, 8, 13 - i, 9, 0));
      }
      expect(await computeStreak(repo: repo, today: today), 5);
    });

    test('连续但今天没学 → 从昨天起算（undefined 今天也算连续）', () async {
      // 8/12、8/11、8/10 连续三天，今天 8/13 还没学
      for (final day in [10, 11, 12]) {
        await addSession(DateTime(2026, 8, day, 9, 0));
      }
      expect(await computeStreak(repo: repo, today: today), 3);
    });

    test('中间断档 → 只数最近一段连续', () async {
      // 8/13 今天 + 8/12 + 8/10（8/11 断档）
      await addSession(DateTime(2026, 8, 13, 9, 0));
      await addSession(DateTime(2026, 8, 12, 9, 0));
      await addSession(DateTime(2026, 8, 10, 9, 0));
      expect(await computeStreak(repo: repo, today: today), 2);
    });

    test('同一天多次会话去重（不重复计数）', () async {
      await addSession(DateTime(2026, 8, 13, 9, 0));
      await addSession(DateTime(2026, 8, 13, 14, 0));
      await addSession(DateTime(2026, 8, 12, 9, 0));
      expect(await computeStreak(repo: repo, today: today), 2);
    });
  });

  group('totalFocusMinutes', () {
    test('累计所有已结束会话，向下取整', () async {
      await addSession(DateTime(2026, 8, 13, 9, 0), durationMs: 1800000); // 30min
      await addSession(DateTime(2026, 8, 12, 9, 0), durationMs: 9000000); // 150min
      await addSession(DateTime(2026, 8, 11, 9, 0), durationMs: 61000);   // 1min + 1s
      expect(await totalFocusMinutes(repo: repo), 181);
    });

    test('进行中会话（duration null）不计', () async {
      await addSession(DateTime(2026, 8, 13, 9, 0)); // ended -> 30min
      final id = await repo.start(DateTime(2026, 8, 13, 10, 0)); // 未结束，duration null
      expect(id, greaterThan(0));
      expect(await totalFocusMinutes(repo: repo), 30);
    });

    test('无记录 → 0', () async {
      expect(await totalFocusMinutes(repo: repo), 0);
    });
  });
}