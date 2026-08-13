// ReviewSessionNotifier（复习会话进度）单元测试。
//
// 验证「再来一组」状态推进：
// 1. init：limit 快照只生效一次。
// 2. next：本组内推进，越界 → done。
// 3. nextSet：setIndex 累计已完成张数（本组实际完成=index+1），index/done 复位，
//    采用新 limit（下次翻页才生效）。
import 'package:flutter_test/flutter_test.dart';
import 'package:study_buddy/features/review/review_providers.dart';

void main() {
  test('init：设置 limit 快照且只生效一次', () {
    final n = ReviewSessionNotifier();
    n.init(30);
    expect(n.state.limit, 30);
    n.init(50); // 已初始化，忽略
    expect(n.state.limit, 30);
  });

  test('next：本组内推进，越界 → done 且 index 停在最后一张', () {
    final n = ReviewSessionNotifier();
    n.next(20);
    expect(n.state.index, 1);
    expect(n.state.done, isFalse);

    // 推进到最后一张（index 19）后 next → done，index 停在 19。
    for (var i = 0; i < 18; i++) {
      n.next(20);
    }
    expect(n.state.index, 19);
    expect(n.state.done, isFalse);

    n.next(20);
    expect(n.state.done, isTrue);
    expect(n.state.index, 19);
  });

  test('nextSet：setIndex 累计已完成张数，index/done 复位，采用新 limit', () {
    final n = ReviewSessionNotifier();
    n.init(20);

    // 评完一组（20 张）：done，index 停在 19。
    for (var i = 0; i < 20; i++) {
      n.next(20);
    }
    expect(n.state.done, isTrue);
    expect(n.state.setIndex, 0);

    // 再来一组：setIndex = 0 + (19+1) = 20，index=0，done=false，limit 用新值。
    n.nextSet(30);
    expect(n.state.setIndex, 20);
    expect(n.state.index, 0);
    expect(n.state.done, isFalse);
    expect(n.state.limit, 30);
  });

  test('nextSet：组中途结束（不足 limit）按实际完成数累计', () {
    final n = ReviewSessionNotifier();
    n.init(20);

    // 只有 5 张的一组：评完 5 张（index 停在 4）后 done。
    for (var i = 0; i < 5; i++) {
      n.next(5);
    }
    expect(n.state.done, isTrue);
    expect(n.state.index, 4);

    n.nextSet(20);
    // 已完成 = setIndex(0) + index+1(5) = 5。
    expect(n.state.setIndex, 5);
    expect(n.state.index, 0);
    expect(n.state.done, isFalse);
  });
}
