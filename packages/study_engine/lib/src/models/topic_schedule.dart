/// 知识点调度状态。FSRS 算法的可观察中间量。
///
/// 字段含义:
/// - [topicId] 关联的 Topic.id(本表不持有外键,业务层保证一致)。
/// - [stability] 稳定性 S(天);值越大下次间隔越长。
/// - [difficulty] 难度 D;范围 [kMinDifficulty, kMaxDifficulty]。
/// - [reps] 累计成功(review)次数。
/// - [lapses] 累计遗忘(forgot)次数。
/// - [lastReviewedAt] 最近一次评分时间;`null` 表示从未复习。
/// - [dueAt] 下次到期时间;`null` 表示尚未安排到期日程。
///
/// 时间字段用毫秒时间戳存储,与本包其它模型一致。
/// `fromMap` 接受 null 表示"该列尚未写入",允许上层在未到到期日时落空。
library;

class TopicSchedule {
  final int topicId;
  final double stability;
  final double difficulty;
  final int reps;
  final int lapses;
  final DateTime? lastReviewedAt;
  final DateTime? dueAt;

  const TopicSchedule({
    required this.topicId,
    required this.stability,
    required this.difficulty,
    required this.reps,
    required this.lapses,
    this.lastReviewedAt,
    this.dueAt,
  });

  factory TopicSchedule.fromMap(Map<String, Object?> m) => TopicSchedule(
        topicId: m['topic_id'] as int,
        stability: (m['stability'] as num).toDouble(),
        difficulty: (m['difficulty'] as num).toDouble(),
        reps: m['reps'] as int,
        lapses: m['lapses'] as int,
        lastReviewedAt: m['last_reviewed_at'] != null
            ? DateTime.fromMillisecondsSinceEpoch(m['last_reviewed_at'] as int)
            : null,
        dueAt: m['due_at'] != null
            ? DateTime.fromMillisecondsSinceEpoch(m['due_at'] as int)
            : null,
      );

  Map<String, Object?> toMap() => {
        'topic_id': topicId,
        'stability': stability,
        'difficulty': difficulty,
        'reps': reps,
        'lapses': lapses,
        if (lastReviewedAt != null) 'last_reviewed_at': lastReviewedAt!.millisecondsSinceEpoch,
        if (dueAt != null) 'due_at': dueAt!.millisecondsSinceEpoch,
      };

  TopicSchedule copyWith({
    int? topicId,
    double? stability,
    double? difficulty,
    int? reps,
    int? lapses,
    DateTime? lastReviewedAt,
    DateTime? dueAt,
  }) {
    return TopicSchedule(
      topicId: topicId ?? this.topicId,
      stability: stability ?? this.stability,
      difficulty: difficulty ?? this.difficulty,
      reps: reps ?? this.reps,
      lapses: lapses ?? this.lapses,
      // lastReviewedAt / dueAt 允许通过 sentinel=null 显式置空?——本模型未引入 sentinel,
      // 保持与 LlmConfig.copyWith 一致的"非 null 才覆盖"语义;如需清空请直接 new。
      lastReviewedAt: lastReviewedAt ?? this.lastReviewedAt,
      dueAt: dueAt ?? this.dueAt,
    );
  }
}
