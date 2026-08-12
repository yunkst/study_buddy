/// 复习评分。四档从忘到易。
///
/// 通过 [RatingX.wire] / [RatingX.fromWire] 与字符串互转,用于持久化与跨层边界。
/// 未知字符串默认映射为 [Rating.good],与 [MasteryStatusX.fromWire] 兜底风格一致。
library;

enum Rating { forgot, hard, good, easy }

extension RatingX on Rating {
  String get wire => name;

  static Rating fromWire(String s) =>
      Rating.values.firstWhere((r) => r.name == s, orElse: () => Rating.good);
}
