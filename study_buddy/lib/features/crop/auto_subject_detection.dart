// 拍题照片主体区域自动识别：纯函数算法层（isolate 内可跑）。
//
// 职责：输入已降采样的 RGBA 字节（UI 侧用 crop_service.downsampleToRgba
// 产出，本文件不碰 ui.Image——isolate 不可发送），输出「最居中的文字/内容
// 区域」在原图（降采样小图坐标系）上的包围盒；置信度不足返回 null，由调用
// 方走「中心默认框」兜底。
//
// 与 UI 解耦：本文件是纯 Dart（仅 typed_data / math / material 的 Rect、Size），
// 零 pub 依赖，可在 `compute()` isolate 里跑，也可纯 test() 手构 RGBA 字节直测。
//
// 算法（拍题场景先验：题目 = 页面上若干密集文字/图形的横向条带）：
//   1) 灰度（Rec.601 整数近似）；
//   2) 积分图加速的局部自适应二值化（Sauvola 简化），抗光照不均；
//   3) 垂直投影 → 行带聚合（连续高密度行合并，gap 容忍断行）；
//   4) 每个 band 列投影取横向极值 → bandRect；
//   5) 合并相邻 band（「单题 = 一组连续文字行」成一个框）；
//   6) 取「最居中 + 墨量」综合得分最高的 band 聚类作为结果，超置信阈值。
//
// 本期定位：只输出最居中的单体（单题区），不做一页多题的切分。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart' show Rect, Offset;

/// [compute()] 的入参容器：compute 要求单参数且顶层/静态函数。
///
/// [rgba] 为降采样小图的 RGBA 字节（rawStraightRgba，长度为 w*h*4）。
class DetectSubjectInput {
  final Uint8List rgba;
  final int width;
  final int height;

  const DetectSubjectInput(this.rgba, this.width, this.height);
}

/// [compute()] isolate 入口：把容器解开后跑核心实现。
Rect? detectSubjectRectInIsolate(DetectSubjectInput input) {
  return _detectSubjectRectImpl(input.rgba, input.width, input.height);
}

/// 单测直调入口：普通参数，不绕 compute。
Rect? detectSubjectRect({
  required Uint8List rgba,
  required int width,
  required int height,
}) {
  return _detectSubjectRectImpl(rgba, width, height);
}

// ─────────────────────────────────────────────────────────
// 核心实现
// ─────────────────────────────────────────────────────────

/// 行带聚合后的一段连续内容（小图像素坐标）。
class _Band {
  int y0;
  int y1;
  int left;
  int right;
  int ink; // 带内墨迹像素总数

  _Band(this.y0, this.y1, this.left, this.right, this.ink);

  int get height => y1 - y0 + 1;

  Rect get rect => Rect.fromLTRB(
        left.toDouble(),
        y0.toDouble(),
        (right + 1).toDouble(),
        (y1 + 1).toDouble(),
      );
}

/// 检测参数（降采样小图像素单位）。集中成常量便于单测调参。
class _Params {
  // 行密度阈值：该行墨迹占比 ≥ 4% 视为「内容行」。
  static const double rowThr = 0.04;
  // 最小 band 高（滤噪点，降采样后单行文字约 8~14px）。
  static const int minBandHeight = 6;
  // 行间空白 ≤ 4 行视为同一 band 内部断行（换行）。
  static const int maxGap = 4;
  // band 合并：垂直间距 ≤ 1.5×band 高 且 列重叠 ≥ 50% 视为同一题块。
  static const double mergeGapFactor = 1.5;
  static const double mergeOverlapRatio = 0.5;
  // Sauvola 参数。
  static const double sauvolaK = 0.2;
  static const double sauvolaR = 128.0;
  // 空白图早退阈值：整图墨迹占比 < 0.5% 视为没内容。
  static const double minTotalInkRatio = 0.005;
  // 置信度：墨量 < 2% 或 短边过小 或 中心偏离 > 0.6 归一化距离 → null。
  static const double minBandInkRatio = 0.02;
  static const double maxCenterDistN = 0.6;
  // 得分权重：优先居中，次之墨量。
  static const double wCenter = 0.7;
  static const double wInk = 0.3;
}

Rect? _detectSubjectRectImpl(Uint8List rgba, int width, int height) {
  if (width <= 0 || height <= 0) return null;
  if (rgba.length < width * height * 4) return null;

  final gray = _toGray(rgba, width, height);

  // 积分图（均值 + 平方）→ O(1) 窗口统计。
  final sat = _SummedArea(width, height, gray, square: false);
  final satSq = _SummedArea(width, height, gray, square: true);

  final ink = _adaptiveBinarize(gray, width, height, sat, satSq);

  final totalInk = _countInk(ink);
  if (totalInk < width * height * _Params.minTotalInkRatio) {
    return null; // 空白图
  }

  // 垂直投影 → 行带聚合。
  final rowProfile = _rowProfile(ink, width, height);
  final bands = _aggregateBands(rowProfile, width, height);

  if (bands.isEmpty) return null;

  // 列范围（每 band 内列投影取墨迹极值）。
  for (final b in bands) {
    _fillBandColumns(b, ink, width);
  }

  // 合并相邻 band → 单题块候选。
  final merged = _mergeBands(bands);

  // 最居中单框 + 置信度。
  return _pickBestCentered(merged, width, height);
}

/// Rec.601 亮度：`(77r + 150g + 23b) / 256`，整数近似。
Uint8List _toGray(Uint8List rgba, int w, int h) {
  final gray = Uint8List(w * h);
  for (var i = 0; i < w * h; i++) {
    final o = i * 4;
    gray[i] = (77 * rgba[o] + 150 * rgba[o + 1] + 23 * rgba[o + 2]) ~/ 256;
  }
  return gray;
}

/// 积分图（summed-area table）。[square] 为 true 时存灰度平方。
class _SummedArea {
  final Int64List data; // 可能溢出 32 位，用 64 位
  final int w;

  _SummedArea(int width, int height, Uint8List gray, {required bool square})
      : w = width,
        data = Int64List((width + 1) * (height + 1)) {
    final W = width + 1;
    for (var y = 0; y < height; y++) {
      var rowSum = 0;
      for (var x = 0; x < width; x++) {
        final v = square
            ? gray[y * width + x] * gray[y * width + x]
            : gray[y * width + x];
        rowSum += v;
        // data[(y+1)*W + (x+1)] = rowSum + 上方同列
        data[(y + 1) * W + (x + 1)] = rowSum + data[y * W + (x + 1)];
      }
    }
  }

  /// 矩形 [x0,x1) × [y0,y1) 的像素和。
  int rectSum(int x0, int y0, int x1, int y1) {
    final W = w + 1;
    return data[y1 * W + x1] -
        data[y0 * W + x1] -
        data[y1 * W + x0] +
        data[y0 * W + x0];
  }
}

/// Sauvola 简化自适应二值化：`ink = gray < m*(1 + k*(s/R - 1))`。
///
/// 窗口边长 = max(7, min(w,h)/15) 取奇数；边沿处窗口缩到图片内。
Uint8List _adaptiveBinarize(
  Uint8List gray,
  int w,
  int h,
  _SummedArea sat,
  _SummedArea satSq,
) {
  final win = math.max(7, math.min(w, h) ~/ 15);
  final winOdd = win % 2 == 0 ? win + 1 : win;
  final half = winOdd ~/ 2;

  final ink = Uint8List(w * h);
  for (var y = 0; y < h; y++) {
    final y0 = math.max(0, y - half);
    final y1 = math.min(h, y + half + 1);
    for (var x = 0; x < w; x++) {
      final x0 = math.max(0, x - half);
      final x1 = math.min(w, x + half + 1);
      final area = (y1 - y0) * (x1 - x0);
      final sum = sat.rectSum(x0, y0, x1, y1);
      final sumSq = satSq.rectSum(x0, y0, x1, y1);
      final mean = sum / area;
      final variance = (sumSq / area) - mean * mean;
      final std = variance <= 0 ? 0.0 : math.sqrt(variance);
      final t = mean * (1 + _Params.sauvolaK * (std / _Params.sauvolaR - 1));
      ink[y * w + x] = gray[y * w + x] < t ? 1 : 0;
    }
  }
  return ink;
}

int _countInk(Uint8List ink) {
  var n = 0;
  for (final v in ink) {
    if (v != 0) n++;
  }
  return n;
}

/// 每行墨迹像素数。
Uint8List _rowProfile(Uint8List ink, int w, int h) {
  final profile = Uint8List(h);
  for (var y = 0; y < h; y++) {
    var n = 0;
    final base = y * w;
    for (var x = 0; x < w; x++) {
      if (ink[base + x] != 0) n++;
    }
    profile[y] = n;
  }
  return profile;
}

/// 行带聚合：把密度 ≥ 阈值的连续行合并，容忍 ≤ maxGap 的内部断行。
List<_Band> _aggregateBands(Uint8List rowProfile, int w, int h) {
  final bands = <_Band>[];
  int? start;
  var gapRun = 0;

  void closeBand(int end) {
    if (end - start! + 1 >= _Params.minBandHeight) {
      bands.add(_Band(start!, end, w, 0, 0));
    }
    start = null;
    gapRun = 0;
  }

  for (var y = 0; y < h; y++) {
    final density = rowProfile[y] / w;
    if (density >= _Params.rowThr) {
      if (start == null) {
        start = y;
        gapRun = 0;
      } else {
        gapRun = 0;
      }
    } else {
      if (start != null) {
        gapRun++;
        if (gapRun > _Params.maxGap) closeBand(y - gapRun);
      }
    }
  }
  if (start != null) closeBand(h - 1);
  return bands;
}

/// 列范围：band 内对每列统计墨迹，取墨迹存在的极值列。
void _fillBandColumns(_Band b, Uint8List ink, int w) {
  var left = w;
  var right = -1;
  for (var y = b.y0; y <= b.y1; y++) {
    final base = y * w;
    for (var x = 0; x < w; x++) {
      if (ink[base + x] != 0) {
        if (x < left) left = x;
        if (x > right) right = x;
        b.ink++;
      }
    }
  }
  b.left = left;
  b.right = right;
}

/// 合并相邻 band：与基准 band 列重叠 ≥ 50% 且 垂直间距 ≤ 1.5×band 高。
///
/// 用并查（贪心双指针）把互相满足条件的 band 聚成同一题块，输出外接 Rect。
List<_Band> _mergeBands(List<_Band> bands) {
  // 已按 y0 排序（聚合顺序保证）。贪心：维护当前块的下界/上界，逐 band 检查。
  final merged = <_Band>[];
  _Band? cur;
  for (final b in bands) {
    if (cur == null) {
      cur = _Band(b.y0, b.y1, b.left, b.right, b.ink);
      continue;
    }
    // 当前块与 b 的列重叠比例（取较窄者分母，避免长块把重叠比稀释）。
    final overlap = _overlapLen(cur.left, cur.right, b.left, b.right);
    final minWidth = math.min(cur.right - cur.left + 1, b.right - b.left + 1);
    final gap = b.y0 - cur.y1;
    if (minWidth > 0 &&
        overlap / minWidth >= _Params.mergeOverlapRatio &&
        gap <= (cur.height * _Params.mergeGapFactor)) {
      // 并入当前块。
      cur = _Band(
        cur.y0,
        b.y1,
        math.min(cur.left, b.left),
        math.max(cur.right, b.right),
        cur.ink + b.ink,
      );
    } else {
      merged.add(cur);
      cur = _Band(b.y0, b.y1, b.left, b.right, b.ink);
    }
  }
  if (cur != null) merged.add(cur);
  return merged;
}

int _overlapLen(int a0, int a1, int b0, int b1) {
  final lo = math.max(a0, b0);
  final hi = math.min(a1, b1);
  return hi >= lo ? hi - lo + 1 : 0;
}

/// 从合并后的候选块里挑「最居中 + 墨量」综合得分最高的一个。
///
/// 置信度不足返回 null（调用方走中心默认框）。
Rect? _pickBestCentered(List<_Band> bands, int w, int h) {
  if (bands.isEmpty) return null;
  final cx = w / 2;
  final cy = h / 2;
  final diag = math.sqrt(w * w + h * h) / 2; // 半对角线，归一化分母

  _Band? best;
  var bestScore = -1.0;
  for (final b in bands) {
    final dcN = (b.rect.center - Offset(cx, cy)).distance / diag;
    final inkN = b.height > 0 ? b.ink / (w * b.height) : 0.0;
    final score = _Params.wCenter * (1 - math.min(dcN, 1.0)) +
        _Params.wInk * math.min(inkN, 1.0);
    if (score > bestScore) {
      bestScore = score;
      best = b;
    }
  }

  if (best == null) return null;

  final rect = best.rect;
  final dcN = (rect.center - Offset(cx, cy)).distance / diag;
  final inkN = best.height > 0 ? best.ink / (w * best.height) : 0.0;
  final shortSide = math.min(rect.width, rect.height);

  // 置信度门槛：短边过小（疑似线噪声）/ 墨量过低 / 明显偏离中心。
  final minShortSide = math.min(8, 0.04 * math.min(w, h));
  if (shortSide < minShortSide) return null;
  if (inkN < _Params.minBandInkRatio) return null;
  if (dcN > _Params.maxCenterDistN) return null;

  return rect;
}
