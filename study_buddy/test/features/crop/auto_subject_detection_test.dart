// auto_subject_detection 纯函数单测：手构 RGBA 字节，不碰 dart:ui，全用 test()。
//
// 覆盖：
// - 白底 + 中央黑块 → 返回覆盖黑块的居中 Rect；
// - 全白图 → null（空白早退）；
// - 角落黑块 → null（偏离中心，dcN > 0.6）；
// - 多行堆叠黑带 → 合并框纵向跨过全部行。
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:study_buddy/features/crop/auto_subject_detection.dart';

/// 构造 w×h 全白 RGBA（含 alpha=255）。
Uint8List _whiteRgba(int w, int h) {
  final rgba = Uint8List(w * h * 4);
  for (var i = 0; i < w * h; i++) {
    final o = i * 4;
    rgba[o] = 255;
    rgba[o + 1] = 255;
    rgba[o + 2] = 255;
    rgba[o + 3] = 255;
  }
  return rgba;
}

/// 在白底上画一个黑色实心矩形 [x0,x1]×[y0,y1]（闭区间）。
void _paintBlackRect(
  Uint8List rgba,
  int w,
  int x0,
  int y0,
  int x1,
  int y1,
) {
  for (var y = y0; y <= y1; y++) {
    for (var x = x0; x <= x1; x++) {
      final o = (y * w + x) * 4;
      rgba[o] = 0;
      rgba[o + 1] = 0;
      rgba[o + 2] = 0;
      rgba[o + 3] = 255;
    }
  }
}

void main() {
  test('白底 + 中央黑块 → 返回覆盖黑块的居中 Rect', () {
    const w = 100, h = 80;
    final rgba = _whiteRgba(w, h);
    // 中央 40×12 黑块：(30..69, 34..45)，中心 (49.5, 39.5)≈图中心 (50,40)。
    _paintBlackRect(rgba, w, 30, 34, 69, 45);

    final r = detectSubjectRect(rgba: rgba, width: w, height: h);
    expect(r, isNotNull);
    // 覆盖黑块（算法可能略外扩或贴合，用宽松包络）。
    expect(r!.left, lessThanOrEqualTo(30));
    expect(r.right, greaterThanOrEqualTo(70));
    expect(r.top, lessThanOrEqualTo(34));
    expect(r.bottom, greaterThanOrEqualTo(46));
    // 中心接近图中心。
    final dc = (r.center - const Offset(50, 40)).distance;
    expect(dc, lessThan(20));
  });

  test('全白图 → null（空白早退）', () {
    const w = 60, h = 40;
    final rgba = _whiteRgba(w, h);
    expect(detectSubjectRect(rgba: rgba, width: w, height: h), isNull);
  });

  test('角落黑块 → null（偏离中心）', () {
    const w = 100, h = 80;
    final rgba = _whiteRgba(w, h);
    // 左上角小黑块 (2..20, 2..10)，明显偏离中心。
    _paintBlackRect(rgba, w, 2, 2, 20, 10);
    expect(detectSubjectRect(rgba: rgba, width: w, height: h), isNull);
  });

  test('多行堆叠黑带 → 合并框纵向跨过全部行', () {
    const w = 100, h = 100;
    final rgba = _whiteRgba(w, h);
    // 三条平行黑带，模拟 3 行题文，行间小 gap：
    //   行1: (20..79, 25..33)
    //   行2: (20..79, 42..50)
    //   行3: (20..79, 59..67)
    _paintBlackRect(rgba, w, 20, 25, 79, 33);
    _paintBlackRect(rgba, w, 20, 42, 79, 50);
    _paintBlackRect(rgba, w, 20, 59, 79, 67);

    final r = detectSubjectRect(rgba: rgba, width: w, height: h);
    expect(r, isNotNull);
    // 合并后应纵向覆盖从首行顶到末行底（68 ≈ 末行底 +1）。
    expect(r!.top, lessThanOrEqualTo(25));
    expect(r.bottom, greaterThanOrEqualTo(68));
  });

  test('非法输入（尺寸 0 / 字节不足）→ null', () {
    expect(detectSubjectRect(rgba: Uint8List(0), width: 0, height: 0), isNull);
    expect(
      detectSubjectRect(rgba: Uint8List(10), width: 4, height: 4),
      isNull, // 字节不足 w*h*4
    );
  });

  test('detectSubjectRectInIsolate 解包容器后等价于直调', () {
    const w = 100, h = 80;
    final rgba = _whiteRgba(w, h);
    _paintBlackRect(rgba, w, 30, 34, 69, 45);
    final direct = detectSubjectRect(rgba: rgba, width: w, height: h);
    final viaIsolate = detectSubjectRectInIsolate(
      DetectSubjectInput(rgba, w, h),
    );
    expect(viaIsolate, direct);
  });
}
