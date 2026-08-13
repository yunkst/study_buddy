// 每日复习上限：用户可配置的复习队列大小。
// 持久化到 SharedPreferences,key='daily_review_limit',int 值(默认 20,范围 1-200)。
// 与 theme_mode_provider / previewChannelProvider 同款 AsyncNotifier 范式:
// build() 读 prefs,set() 写 prefs 并立即更新 state。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

final dailyReviewLimitProvider =
    AsyncNotifierProvider<DailyReviewLimitNotifier, int>(
  DailyReviewLimitNotifier.new,
);

class DailyReviewLimitNotifier extends AsyncNotifier<int> {
  static const _key = 'daily_review_limit';

  /// 默认值与 study_engine 的 kDailyReviewCap(20) 对齐。
  static const defaultValue = 20;

  /// 用户可配置范围下限。
  static const minValue = 1;

  /// 用户可配置范围上限。
  static const maxValue = 200;

  @override
  Future<int> build() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getInt(_key) ?? defaultValue;
    return v.clamp(minValue, maxValue);
  }

  /// 写入并立即更新 state。clamp 到合法范围防御未来误改。
  Future<void> set(int value) async {
    final clamped = value.clamp(minValue, maxValue);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_key, clamped);
    state = AsyncData(clamped);
  }
}
