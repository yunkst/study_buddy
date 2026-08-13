/// 学习计划三模型。对应 v3 新增表，不依赖 Flutter。
library;

/// 学习计划本体：用户给定的目标元信息。
class Plan {
  final int? id;
  final String name;
  final DateTime examDate;
  final String examContent;
  final String target;
  final int dailyMinutes;
  final String? currentLevel;
  final DateTime createdAt;
  final DateTime updatedAt;
  const Plan({
    this.id,
    required this.name,
    required this.examDate,
    required this.examContent,
    required this.target,
    required this.dailyMinutes,
    this.currentLevel,
    required this.createdAt,
    required this.updatedAt,
  });

  factory Plan.fromMap(Map<String, Object?> m) => Plan(
        id: m['id'] as int?,
        name: m['name'] as String,
        examDate: DateTime.fromMillisecondsSinceEpoch(m['exam_date'] as int),
        examContent: m['exam_content'] as String,
        target: m['target'] as String,
        dailyMinutes: m['daily_minutes'] as int,
        currentLevel: m['current_level'] as String?,
        createdAt: DateTime.fromMillisecondsSinceEpoch(m['created_at'] as int),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(m['updated_at'] as int),
      );
  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'name': name,
        'exam_date': examDate.millisecondsSinceEpoch,
        'exam_content': examContent,
        'target': target,
        'daily_minutes': dailyMinutes,
        if (currentLevel != null) 'current_level': currentLevel,
        'created_at': createdAt.millisecondsSinceEpoch,
        'updated_at': updatedAt.millisecondsSinceEpoch,
      };
}

/// 里程碑节点：AI 拆出的阶段目标，按时间线序列排。
class Milestone {
  final int? id;
  final int planId;
  final String title;
  final String description;
  final DateTime targetDate;
  final int sortOrder;
  final String status; // 'pending' | 'done'
  final DateTime createdAt;
  final DateTime updatedAt;
  const Milestone({
    this.id,
    required this.planId,
    required this.title,
    required this.description,
    required this.targetDate,
    this.sortOrder = 0,
    this.status = 'pending',
    required this.createdAt,
    required this.updatedAt,
  });

  factory Milestone.fromMap(Map<String, Object?> m) => Milestone(
        id: m['id'] as int?,
        planId: m['plan_id'] as int,
        title: m['title'] as String,
        description: m['description'] as String,
        targetDate: DateTime.fromMillisecondsSinceEpoch(m['target_date'] as int),
        sortOrder: (m['sort_order'] as int?) ?? 0,
        status: m['status'] as String,
        createdAt: DateTime.fromMillisecondsSinceEpoch(m['created_at'] as int),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(m['updated_at'] as int),
      );
  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'plan_id': planId,
        'title': title,
        'description': description,
        'target_date': targetDate.millisecondsSinceEpoch,
        'sort_order': sortOrder,
        'status': status,
        'created_at': createdAt.millisecondsSinceEpoch,
        'updated_at': updatedAt.millisecondsSinceEpoch,
      };
}

/// 测评记录：手动录分，承载进步曲线数据点。score 可空（无法量化时只记 note）。
class Assessment {
  final int? id;
  final int planId;
  final int? score;
  final String? note;
  final DateTime assessedAt;
  final DateTime createdAt;
  const Assessment({
    this.id,
    required this.planId,
    required this.score,
    this.note,
    required this.assessedAt,
    required this.createdAt,
  });

  factory Assessment.fromMap(Map<String, Object?> m) => Assessment(
        id: m['id'] as int?,
        planId: m['plan_id'] as int,
        score: m['score'] as int?,
        note: m['note'] as String?,
        assessedAt: DateTime.fromMillisecondsSinceEpoch(m['assessed_at'] as int),
        createdAt: DateTime.fromMillisecondsSinceEpoch(m['created_at'] as int),
      );
  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'plan_id': planId,
        if (score != null) 'score': score,
        if (note != null) 'note': note,
        'assessed_at': assessedAt.millisecondsSinceEpoch,
        'created_at': createdAt.millisecondsSinceEpoch,
      };
}

/// 每日打卡任务。挂在某 plan 下，绑定一个具体本地日历日。
/// task_date 存本地零点 millis（见 PlanDayTaskRepository）。
class PlanDayTask {
  final int? id;
  final int planId;
  final DateTime taskDate;
  final String title;
  final int sortOrder;
  final String status; // 'pending' | 'done'
  final DateTime? doneAt;
  final DateTime createdAt;
  final DateTime updatedAt;
  const PlanDayTask({
    this.id,
    required this.planId,
    required this.taskDate,
    required this.title,
    this.sortOrder = 0,
    this.status = 'pending',
    this.doneAt,
    required this.createdAt,
    required this.updatedAt,
  });

  factory PlanDayTask.fromMap(Map<String, Object?> m) => PlanDayTask(
        id: m['id'] as int?,
        planId: m['plan_id'] as int,
        taskDate: DateTime.fromMillisecondsSinceEpoch(m['task_date'] as int),
        title: m['title'] as String,
        sortOrder: (m['sort_order'] as int?) ?? 0,
        status: m['status'] as String,
        doneAt: m['done_at'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(m['done_at'] as int),
        createdAt: DateTime.fromMillisecondsSinceEpoch(m['created_at'] as int),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(m['updated_at'] as int),
      );

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'plan_id': planId,
        'task_date': taskDate.millisecondsSinceEpoch,
        'title': title,
        'sort_order': sortOrder,
        'status': status,
        if (doneAt != null) 'done_at': doneAt!.millisecondsSinceEpoch,
        'created_at': createdAt.millisecondsSinceEpoch,
        'updated_at': updatedAt.millisecondsSinceEpoch,
      };
}
