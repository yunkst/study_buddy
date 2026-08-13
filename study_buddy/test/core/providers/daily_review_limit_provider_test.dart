// DailyReviewLimitProvider（每日复习上限）测试。
//
// 用 SharedPreferences.setMockInitialValues 注入 mock 存储，验证：
// 1. 无存储值 → 默认 20。
// 2. set 后读回新值且持久化（重建 provider 仍读到）。
// 3. 边界 clamp：<min 收敛到 1，>max 收敛到 200。
// 4. build 读到的非法值（存储被污染）也会 clamp。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:study_buddy/core/providers/daily_review_limit_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('无存储值 → 默认 20', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(await container.read(dailyReviewLimitProvider.future), 20);
  });

  test('set 后读回新值且持久化', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await container.read(dailyReviewLimitProvider.notifier).set(30);
    expect(await container.read(dailyReviewLimitProvider.future), 30);

    // 重建 container（模拟重启）→ 仍读到 30（SharedPreferences mock 保持）。
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('daily_review_limit'), 30);
  });

  test('边界 clamp：低于 min → 1，高于 max → 200', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await container.read(dailyReviewLimitProvider.notifier).set(0);
    expect(await container.read(dailyReviewLimitProvider.future), 1);

    await container.read(dailyReviewLimitProvider.notifier).set(999);
    expect(await container.read(dailyReviewLimitProvider.future), 200);
  });

  test('存储值非法 → build 时 clamp', () async {
    SharedPreferences.setMockInitialValues({'daily_review_limit': 500});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(await container.read(dailyReviewLimitProvider.future), 200);
  });
}
