import 'dart:math' as math;

import 'package:sqflite_common/sqlite_api.dart';

import '../db/database.dart';
import '../models/models.dart';
import '../review_scheduler/params.dart';

/// `topic_schedule` 表的仓储：FSRS 调度状态的持久化、到期队列、新卡计数、
/// 以及 `set_mastery` 对 S/D 的修正（spec §7.3）。
///
/// 所有时间字段以毫秒时间戳读写（与 [TopicSchedule] 模型约定一致）。
class TopicScheduleRepository {
  final StudyDatabase _db;
  TopicScheduleRepository(this._db);

  /// 查某知识点的调度行；不存在返回 null。
  Future<TopicSchedule?> findByTopic(int topicId) async {
    final rows = await _db.db.query(
      'topic_schedule',
      where: 'topic_id = ?',
      whereArgs: [topicId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return TopicSchedule.fromMap(rows.first);
  }

  /// 插入或覆盖（[ConflictAlgorithm.replace]）一行。
  Future<void> upsert(TopicSchedule s) async {
    await _db.db.insert(
      'topic_schedule',
      s.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 删除某知识点的调度行。
  Future<void> delete(int topicId) async {
    await _db.db.delete(
      'topic_schedule',
      where: 'topic_id = ?',
      whereArgs: [topicId],
    );
  }

  /// 今日到期队列：`due_at <= now`，按 `(due_at - now) ASC, stability ASC`
  /// 排序——逾期越久越优先，同逾期时 stability 越低越优先（最该抢救的在前）。
  ///
  /// [limit] 默认 [kDailyReviewCap]；[offset] 用于分页。
  Future<List<TopicSchedule>> dueNow(
    DateTime now, {
    int limit = kDailyReviewCap,
    int offset = 0,
  }) async {
    final nowMs = now.millisecondsSinceEpoch;
    final rows = await _db.db.rawQuery(
      '''
      SELECT * FROM topic_schedule
      WHERE due_at IS NOT NULL AND due_at <= ?
      ORDER BY (due_at - ?) ASC, stability ASC
      LIMIT ? OFFSET ?
      ''',
      [nowMs, nowMs, limit, offset],
    );
    return rows.map(TopicSchedule.fromMap).toList();
  }

  /// `set_mastery` 对 S/D 的修正（spec §7.3）。
  ///
  /// 不存在该知识点的行时按 [status] 推导 S/D 创建。各 status 修正语义：
  /// - [MasteryStatus.weak]：`S = min(S, kWeakStabilityCeiling)`、
  ///   `D = max(D, kMinDifficultyFloorForWeak)`
  /// - [MasteryStatus.mastered]：`S = max(S, kMasteredStabilityFloor)`
  /// - [MasteryStatus.learning]：`S = clamp(S, kLearningStabilityFloor,
  ///   kLearningStabilityCeiling)`
  /// - [MasteryStatus.unknown]：`S = kUnknownResetStability`（视作遗忘）
  ///
  /// 修正后 `lastReviewedAt = now`，`dueAt = now + max(1, round(S)) 天`。
  /// 返回落库后的最新行。
  Future<TopicSchedule> applyMasteryOverride({
    required int topicId,
    required MasteryStatus status,
    DateTime? now,
  }) async {
    final at = now ?? DateTime.now();
    final existing = await findByTopic(topicId);
    final sPrev = existing?.stability;
    final dPrev = existing?.difficulty;
    const defaultDifficulty = 5.0;

    double newS;
    double newD = dPrev ?? defaultDifficulty;
    switch (status) {
      case MasteryStatus.weak:
        // S = min(S, 0.5)；不存在时把 S 当 +∞ 处理 → 0.5。
        final base = sPrev ?? double.infinity;
        newS = math.min(base, kWeakStabilityCeiling);
        newD = math.max(dPrev ?? defaultDifficulty, kMinDifficultyFloorForWeak);
      case MasteryStatus.mastered:
        final base = sPrev ?? 0.0;
        newS = math.max(base, kMasteredStabilityFloor);
      case MasteryStatus.learning:
        final base = sPrev ?? kLearningStabilityFloor;
        newS = base.clamp(kLearningStabilityFloor, kLearningStabilityCeiling)
            .toDouble();
      case MasteryStatus.unknown:
        newS = kUnknownResetStability;
    }

    final reps = existing?.reps ?? 0;
    final lapses = existing?.lapses ?? 0;
    final intervalDays = math.max(1, newS.round());
    final next = TopicSchedule(
      topicId: topicId,
      stability: newS,
      difficulty: newD,
      reps: reps,
      lapses: lapses,
      // 新建行（existing == null）lastReviewedAt 置 null：该知识点从未经 FSRS
      // 评分 UI 首评，不应被 firstGradeCountToday 计入「今日已首评」而烧掉新卡额度；
      // 已有行仍写 at（本次 set_mastery 即一次真实触点）。
      lastReviewedAt: existing == null ? null : at,
      dueAt: at.add(Duration(days: intervalDays)),
    );
    await upsert(next);
    return next;
  }

  /// 今日已完成首次评分的新卡数（新卡上限用）。
  ///
  /// 口径：`last_reviewed_at >= 今日零点 且 reps == 0`（reps==0 表示仍处首评循环；
  /// 首评成功会变 1）。今日零点由 [now] 当日 00:00:00 计算。
  Future<int> firstGradeCountToday(DateTime now) async {
    final todayMidnight = DateTime(now.year, now.month, now.day);
    final rows = await _db.db.rawQuery(
      '''
      SELECT COUNT(*) AS c FROM topic_schedule
      WHERE last_reviewed_at >= ? AND reps = 0
      ''',
      [todayMidnight.millisecondsSinceEpoch],
    );
    final c = rows.first['c'];
    return (c as num).toInt();
  }
}
