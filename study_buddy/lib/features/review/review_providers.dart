/// FSRS 复习模块：今日队列、会话进度状态、评分动作。
/// Task 6.1：封装 Phase 6 复习流的 Riverpod 入口；不依赖 UI 层。
library;

// Riverpod 3 默认不再导出 StateNotifier/StateNotifierProvider,
// 走 legacy.dart 兼容入口以匹配 brief 的 StateNotifier 语义。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:study_engine/study_engine.dart';

import '../../core/providers/daily_review_limit_provider.dart';
import '../../core/providers/database_provider.dart';
import '../../core/providers/topic_schedule_provider.dart';

/// 会话内「再来一组」最多支持的组数：一次查够 limit × kMaxReviewSets 张，
/// 在内存里按 setIndex 切片翻页（避免会话中途评分改变 dueAt 导致 LIMIT/OFFSET
/// 分页错位）。取上限与 dailyReviewLimitProvider.maxValue(200) 对齐。
const int kMaxReviewSets = 10;

/// 今日复习队列：按用户每日复习上限一次查够多组，供会话内内存切片翻页。
/// autoDispose：离开复习页即丢弃缓存，重新进入自动重查（新建知识点自动可见）。
final reviewQueueProvider =
    FutureProvider.autoDispose<List<TopicSchedule>>((ref) async {
  final repo = await ref.watch(topicScheduleRepositoryProvider.future);
  final limit = await ref.watch(dailyReviewLimitProvider.future);
  final fetchLimit = (limit * kMaxReviewSets).clamp(1, 200);
  return repo.dueNow(DateTime.now(), limit: fetchLimit);
});

/// 单个知识点查询（按 id）。复习页通过 schedule.topicId 拿到对应 Topic；
/// 返回 null 表示该 topic 已被删除（schedule 仍挂在 topic_schedule 表里）。
final reviewTopicProvider = FutureProvider.family<Topic?, int>((ref, topicId) async {
  final db = await ref.watch(databaseProvider.future);
  return TopicRepository(db).findById(topicId);
});

/// 复习会话进度。
class ReviewSessionState {
  /// 本组内第几张（0 基）。
  final int index;

  /// 本组是否完成。
  final bool done;

  /// 已完成的总张数（下一组起点 offset，只增不减）。
  final int setIndex;

  /// 本组大小快照（用户改上限后下次翻页才生效）。
  final int limit;

  const ReviewSessionState({
    this.index = 0,
    this.done = false,
    this.setIndex = 0,
    this.limit = 20, // 默认与 kDailyReviewCap 对齐；进入会话时由 init 覆盖
  });

  ReviewSessionState copyWith({int? index, bool? done, int? setIndex, int? limit}) =>
      ReviewSessionState(
        index: index ?? this.index,
        done: done ?? this.done,
        setIndex: setIndex ?? this.setIndex,
        limit: limit ?? this.limit,
      );
}

/// 复习会话控制器：next(index+1, 越界则 done=true)、init(设置本组大小)、
/// nextSet(再来一组)、reset(回到首张)。
class ReviewSessionNotifier extends StateNotifier<ReviewSessionState> {
  ReviewSessionNotifier() : super(const ReviewSessionState());

  bool _inited = false;

  /// 会话开始：用当前每日复习上限覆盖本组大小。autoDispose 下每次进入
  /// 都是全新 Notifier，_inited 归 false，本方法必然执行一次。
  void init(int limit) {
    if (_inited) return;
    _inited = true;
    state = state.copyWith(limit: limit);
  }

  /// 推进到下一张：越界 → done:true（index 停在最后一张）。
  void next(int total) {
    if (total <= 0) {
      state = state.copyWith(done: true);
      return;
    }
    final i = state.index + 1;
    state = i >= total ? state.copyWith(done: true) : state.copyWith(index: i);
  }

  /// 再来一组：setIndex 累计已完成张数（本组实际完成 = index+1），index 归零，
  /// done 复位。[newLimit] 为当前每日复习上限（下次翻页才生效）。
  void nextSet(int newLimit) {
    state = ReviewSessionState(
      setIndex: state.setIndex + state.index + 1,
      index: 0,
      done: false,
      limit: newLimit,
    );
  }

  void reset() => state = const ReviewSessionState();
}

final reviewSessionProvider =
    StateNotifierProvider.autoDispose<ReviewSessionNotifier, ReviewSessionState>(
  (ref) => ReviewSessionNotifier(),
);

/// 评分动作（含新卡上限执行）：
/// 1. 若 schedule.reps == 0（新卡首评）→ 先查 repo.firstGradeCountToday(now)；
///    若 >= kDailyNewCardCap(5) → 该卡顺延：due=明天、reps 不变、不调 grade，
///    直接返回 false 表示"额度用尽"。
/// 2. 否则 ReviewScheduler.grade → repo.upsert → 返回 true。
///
/// 参数用 [WidgetRef]：唯一调用方是复习页（widget 层）；Riverpod 3 中
/// WidgetRef 与 Ref 是平级 sealed 类型，不可互转。
Future<bool> gradeAndUpsert(
  WidgetRef ref, {
  required TopicSchedule schedule,
  required Rating rating,
  required DateTime now,
}) async {
  final repo = await ref.read(topicScheduleRepositoryProvider.future);
  if (schedule.reps == 0) {
    final gradedToday = await repo.firstGradeCountToday(now);
    if (gradedToday >= kDailyNewCardCap) {
      // 新卡额度用尽：顺延到明天（reps 不变、不调 grade），保持原 S/D。
      final tomorrow = DateTime(now.year, now.month, now.day + 1);
      await repo.upsert(schedule.copyWith(dueAt: tomorrow));
      return false;
    }
  }
  final updated = ReviewScheduler.grade(
    schedule: schedule,
    rating: rating,
    now: now,
  );
  await repo.upsert(updated);
  return true;
}
