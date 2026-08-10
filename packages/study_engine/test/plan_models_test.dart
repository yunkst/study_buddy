import 'package:test/test.dart';
import 'package:study_engine/study_engine.dart';

void main() {
  test('Plan toMap/fromMap 往返', () {
    final now = DateTime.utc(2026, 8, 10);
    final p = Plan(
      name: '考研冲刺',
      examDate: DateTime.utc(2026, 12, 21),
      examContent: '政治、英语一、数学一、408',
      target: '总分 380',
      dailyMinutes: 180,
      currentLevel: '估 300 分，数学最弱',
      createdAt: now,
      updatedAt: now,
    );
    final m = p.toMap();
    expect(m['name'], '考研冲刺');
    expect(m['daily_minutes'], 180);
    expect(m['exam_date'], DateTime.utc(2026, 12, 21).millisecondsSinceEpoch);
    final back = Plan.fromMap({'id': 1, ...m});
    expect(back.id, 1);
    expect(back.name, '考研冲刺');
    expect(back.examDate.millisecondsSinceEpoch, DateTime.utc(2026, 12, 21).millisecondsSinceEpoch);
    expect(back.dailyMinutes, 180);
  });

  test('Milestone toMap/fromMap 往返含 status', () {
    final now = DateTime.utc(2026, 8, 10);
    final ms = Milestone(
      planId: 1,
      title: '数学基础过完',
      description: '高数+线代基础课，能做基础题',
      targetDate: DateTime.utc(2026, 9, 30),
      sortOrder: 2,
      status: 'pending',
      createdAt: now,
      updatedAt: now,
    );
    final m = ms.toMap();
    expect(m['plan_id'], 1);
    expect(m['status'], 'pending');
    expect(m['sort_order'], 2);
    final back = Milestone.fromMap({'id': 5, ...m});
    expect(back.id, 5);
    expect(back.status, 'pending');
    expect(back.targetDate.millisecondsSinceEpoch, DateTime.utc(2026, 9, 30).millisecondsSinceEpoch);
  });

  test('Assessment toMap/fromMap 往返含可空 score', () {
    final now = DateTime.utc(2026, 8, 20);
    final a = Assessment(
      planId: 1,
      score: 310,
      note: '线代大题崩了',
      assessedAt: now,
      createdAt: now,
    );
    final m = a.toMap();
    expect(m['score'], 310);
    expect(m['note'], '线代大题崩了');
    final back = Assessment.fromMap({'id': 3, ...m});
    expect(back.id, 3);
    expect(back.score, 310);

    // score 为 null
    final a2 = Assessment(planId: 1, score: null, note: '定性：感觉有进步', assessedAt: now, createdAt: now);
    expect(a2.toMap()['score'], isNull);
    final back2 = Assessment.fromMap({'id': 4, ...a2.toMap()});
    expect(back2.score, isNull);
  });
}
