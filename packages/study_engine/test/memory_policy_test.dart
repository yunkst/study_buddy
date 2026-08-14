import 'package:test/test.dart';
import 'package:study_engine/study_engine.dart';

void main() {
  test('kMaxMemoryChars 为 2000', () {
    expect(kMaxMemoryChars, 2000);
  });

  test('totalChars 累加各条目字符数', () {
    expect(totalChars(['abc', 'de']), 5);
    expect(totalChars([]), 0);
  });

  test('isOverBudget：恰等于上限不算超', () {
    final one = List<String>.filled(500, 'x'); // 500 chars
    final two = [...one, ...one, ...one, ...one]; // 2000 chars，恰等于
    expect(isOverBudget(two), isFalse);
  });

  test('isOverBudget：超一字符算超', () {
    final base = List<String>.filled(2000, 'x'); // 2000 chars
    expect(isOverBudget(base, additional: ['y']), isTrue);
  });

  test('isOverBudget：additional 计入', () {
    final existing = List<String>.filled(1500, 'x'); // 1500
    expect(isOverBudget(existing, additional: List.filled(400, 'y')), isFalse); // 1900
    expect(isOverBudget(existing, additional: List.filled(600, 'y')), isTrue); // 2100
  });

  test('isDuplicate：trim 后比较', () {
    expect(isDuplicate(['  偏好A  '], '偏好A'), isTrue);
    expect(isDuplicate(['偏好A'], '偏好B'), isFalse);
    expect(isDuplicate([], '任何'), isFalse);
  });
}
