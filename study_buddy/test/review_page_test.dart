import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:study_buddy/core/providers/knowledge_providers.dart';
import 'package:study_buddy/features/review/review_page.dart';
import 'package:study_engine/study_engine.dart';

/// 假队列仓库：todayNew 返回两张卡，due 为空。
class FakeQueueRepository implements ReviewQueueRepository {
  @override
  Future<List<ReviewQueueItem>> dueQueue(DateTime now, {int limit = 200}) async => [];
  @override
  Future<List<ReviewQueueItem>> todayNewQueue(DateTime startOfDay) async => [
        ReviewQueueItem(1, '洛必达法则', '如何求0/0型极限？'),
        ReviewQueueItem(2, '夹逼定理', '如何证明极限存在？'),
      ];
}

/// 假调度仓库：记录 upsert 调用。
class FakeScheduleRepository implements ReviewScheduleRepository {
  final List<ReviewSchedule> saved = [];
  @override
  Future<ReviewSchedule?> getByTopic(int topicId) async => null; // 全部视为首学
  @override
  Future<void> upsert(ReviewSchedule s) async => saved.add(s);
  @override
  Future<List<ReviewSchedule>> findDue(DateTime now, {int limit = 200}) async => [];
}

/// 假 topic 仓库：findById 返回含 summary 的真 topic（_reveal 主路径）。
class FakeTopicRepository implements TopicRepository {
  @override
  Future<Topic?> findById(int id) async => Topic(
        categoryId: 1,
        question: '如何求0/0型极限？',
        title: '洛必达法则',
        summary: '对分子分母同时求导。',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
  @override
  Future<int> insert(Topic t) async => throw UnimplementedError();
  @override
  Future<Topic?> findByTitle(String title) async => throw UnimplementedError();
  @override
  Future<List<Topic>> findByCategory(int categoryId) async => throw UnimplementedError();
  @override
  Future<TopicSearchResult> search(String keyword,
          {int limit = 30, int offset = 0}) async =>
      throw UnimplementedError();
  @override
  Future<void> updateSummary(int id, String summary) async =>
      throw UnimplementedError();
}

void main() {
  late FakeScheduleRepository fakeSched;

  /// [topics] 传入时 _reveal 走主路径（返回真 topic）；不传则 reject 走 catch 回退。
  Widget build({TopicRepository? topics}) => ProviderScope(
        overrides: [
          reviewQueueRepositoryProvider.overrideWith((ref) async => FakeQueueRepository()),
          reviewScheduleRepositoryProvider.overrideWith((ref) async => fakeSched),
          // 揭晓答案会 ref.read(topicRepositoryProvider.future)。
          // 测试环境无 DB，默认显式 reject 让 _reveal 走 catch 回退标题，
          // 卡片仍可推进——验证容错路径（与生产 DB 不可用时行为一致）。
          // 传 topics 时走主路径（summary 正常渲染）。
          topicRepositoryProvider.overrideWith(
            (ref) async => topics ?? (throw StateError('no db in test')),
          ),
        ],
        child: const MaterialApp(home: ReviewPage()),
      );

  setUp(() => fakeSched = FakeScheduleRepository());

  testWidgets('卡片流程：引子→揭晓→三档→下一张→统计', (tester) async {
    await tester.pumpWidget(build());
    await tester.pumpAndSettle();

    // 第一张引子
    expect(find.text('如何求0/0型极限？'), findsOneWidget);
    expect(find.text('揭晓答案'), findsOneWidget);

    await tester.tap(find.text('揭晓答案'));
    await tester.pumpAndSettle();

    // 揭晓后显示答案 + 三档
    expect(find.text('记得'), findsOneWidget);
    expect(find.text('忘了'), findsOneWidget);
    expect(find.text('轻松'), findsOneWidget);

    await tester.tap(find.text('记得'));
    await tester.pumpAndSettle();

    // 第二张引子
    expect(find.text('如何证明极限存在？'), findsOneWidget);
    expect(fakeSched.saved, hasLength(1)); // 首学记得 → interval 1
    expect(fakeSched.saved.first.intervalDays, 1);

    // 跳过第二张的反馈：直接验证状态可前进——再揭晓 + 轻松
    await tester.tap(find.text('揭晓答案'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('轻松'));
    await tester.pumpAndSettle();

    // 队列耗尽 → 统计
    expect(fakeSched.saved, hasLength(2));
    expect(fakeSched.saved.last.intervalDays, 2); // 首学轻松
    expect(find.textContaining('记得 1'), findsOneWidget);
    expect(find.textContaining('轻松 1'), findsOneWidget);
  });

  testWidgets('揭晓主路径：topic 有 summary 时渲染答案正文而非标题回退', (tester) async {
    await tester.pumpWidget(build(topics: FakeTopicRepository()));
    await tester.pumpAndSettle();

    // 引子
    expect(find.text('如何求0/0型极限？'), findsOneWidget);

    await tester.tap(find.text('揭晓答案'));
    await tester.pumpAndSettle();

    // 渲染 summary 正文（而非 title 回退）
    expect(find.text('对分子分母同时求导。'), findsOneWidget);
    // 无错误/回退提示 SnackBar
    expect(find.textContaining('加载答案失败'), findsNothing);
    expect(find.textContaining('知识点不存在'), findsNothing);
    // 三档仍可推进
    expect(find.text('记得'), findsOneWidget);
  });
}
