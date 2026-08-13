// 拍题全屏裁剪页：拍照/相册选图后，框选题目区域再进 AI 分析。
//
// 职责（仅渲染 + 手势）：
// - 用 LayoutBuilder + 手算 BoxFit.contain，把源图完整居中显示在画布上，
//   得到 `imageDisplayRect`（局部坐标系），全程无依赖 post-frame 取 RenderBox；
// - 维护裁剪框 `_cropRect`（初始 = 整张图边界 = imageDisplayRect），
//   支持 8 手柄（4 角 + 4 边中点）与框内平移；
// - 底部「取消 / 确认裁剪」，确认时调 crop_service 像素裁剪并 `pop<CapturedScreenshot>`。
//
// 裁剪页只 `Navigator.pop` 结果，不在这里调 showAiPanel —— 避免裁剪页 dispose 后
// ProviderScope.containerOf 容器失效（见 ai_panel_sheet.dart:31 的 showAiPanel 注）。
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/providers/captured_image.dart';
import '../../core/theme/crop_frame_painter.dart';
import '../../core/theme/paper_extension.dart';
import '../../core/theme/paper_scaffold.dart';
import 'crop_service.dart';

/// 全屏裁剪页。[sourceBytes] 为待裁剪的原图字节（拍照 / 相册 JPEG/PNG）。
///
/// 确认后将 `Navigator.pop<CapturedScreenshot>(cropped)`；用户取消则 `pop(null)`。
class ImageCropPage extends StatefulWidget {
  const ImageCropPage({super.key, required this.sourceBytes});

  final Uint8List sourceBytes;

  @override
  State<ImageCropPage> createState() => _ImageCropPageState();
}

/// 手势命中模式：无 / 平移 / 8 个手柄方向。
enum _DragMode {
  none,
  move,
  resizeNW,
  resizeNE,
  resizeSW,
  resizeSE,
  resizeN,
  resizeS,
  resizeW,
  resizeE,
}

class _ImageCropPageState extends State<ImageCropPage> {
  ui.Image? _decoded; // 异步解码产物，dispose 释放
  bool _decoding = true; // 初始加载动画
  bool _loadFailed = false; // 解码失败标记
  Size _imagePixelSize = Size.zero;
  Rect _imageDisplayRect = Rect.zero; // 图片 contain 后居中显示矩形
  Rect _cropRect = Rect.zero; // 当前裁剪框（⊆ _imageDisplayRect）
  bool _busy = false; // 确认裁剪中
  _DragMode _dragMode = _DragMode.none;

  /// 手柄命中半径（裁剪框交点附近判定命中）。
  static const double _handleRadius = 18;

  /// 裁剪框最小边长（逻辑 px）。
  static const double _minSide = 48;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final img = await decodeSourceImage(widget.sourceBytes);
      if (!mounted) {
        img.dispose();
        return;
      }
      setState(() {
        _decoded = img;
        _imagePixelSize = Size(img.width.toDouble(), img.height.toDouble());
        _decoding = false;
        _loadFailed = false;
      });
    } on Exception {
      if (mounted) {
        setState(() {
          _decoding = false;
          _loadFailed = true;
        });
      }
    }
  }

  @override
  void dispose() {
    _decoded?.dispose();
    super.dispose();
  }

  // ─────────────────────────────────────────────────────────
  // 手势：统一处理 8 手柄 + 平移
  // ─────────────────────────────────────────────────────────

  void _onPanStart(DragStartDetails details) {
    if (_busy || _imageDisplayRect.isEmpty) return;
    _dragMode = _hitMode(details.localPosition);
  }

  /// 命中判定：先角点，再边中点，最后（在裁剪框内）→ 平移，否则 none。
  _DragMode _hitMode(Offset p) {
    // 四角
    final corners = <({Offset c, _DragMode mode})>[
      (c: _cropRect.topLeft, mode: _DragMode.resizeNW),
      (c: _cropRect.topRight, mode: _DragMode.resizeNE),
      (c: _cropRect.bottomLeft, mode: _DragMode.resizeSW),
      (c: _cropRect.bottomRight, mode: _DragMode.resizeSE),
    ];
    for (final corner in corners) {
      if ((p - corner.c).distance <= _handleRadius) return corner.mode;
    }
    // 四边中点
    final edges = <({Offset c, _DragMode mode})>[
      (c: Offset(_cropRect.center.dx, _cropRect.top), mode: _DragMode.resizeN),
      (
        c: Offset(_cropRect.center.dx, _cropRect.bottom),
        mode: _DragMode.resizeS,
      ),
      (c: Offset(_cropRect.left, _cropRect.center.dy), mode: _DragMode.resizeW),
      (
        c: Offset(_cropRect.right, _cropRect.center.dy),
        mode: _DragMode.resizeE,
      ),
    ];
    for (final edge in edges) {
      if ((p - edge.c).distance <= _handleRadius * 0.9) return edge.mode;
    }
    // 框内 → 平移
    if (_cropRect.contains(p)) return _DragMode.move;
    return _DragMode.none;
  }

  void _onPanUpdate(DragUpdateDetails details) {
    if (_dragMode == _DragMode.none || _imageDisplayRect.isEmpty) return;
    setState(() => _applyDrag(details.delta));
  }

  void _onPanEnd(DragEndDetails details) => _dragMode = _DragMode.none;

  /// 按 mode 更新 _cropRect（平移 / 改边），最后统一 clamp。
  void _applyDrag(Offset delta) {
    var next = _cropRect;
    switch (_dragMode) {
      case _DragMode.none:
      case _DragMode.move:
        next = _cropRect.shift(delta);
      case _DragMode.resizeNW:
        next = Rect.fromLTRB(
          _cropRect.left + delta.dx,
          _cropRect.top + delta.dy,
          _cropRect.right,
          _cropRect.bottom,
        );
      case _DragMode.resizeNE:
        next = Rect.fromLTRB(
          _cropRect.left,
          _cropRect.top + delta.dy,
          _cropRect.right + delta.dx,
          _cropRect.bottom,
        );
      case _DragMode.resizeSW:
        next = Rect.fromLTRB(
          _cropRect.left + delta.dx,
          _cropRect.top,
          _cropRect.right,
          _cropRect.bottom + delta.dy,
        );
      case _DragMode.resizeSE:
        next = Rect.fromLTRB(
          _cropRect.left,
          _cropRect.top,
          _cropRect.right + delta.dx,
          _cropRect.bottom + delta.dy,
        );
      case _DragMode.resizeN:
        next = Rect.fromLTRB(
          _cropRect.left,
          _cropRect.top + delta.dy,
          _cropRect.right,
          _cropRect.bottom,
        );
      case _DragMode.resizeS:
        next = Rect.fromLTRB(
          _cropRect.left,
          _cropRect.top,
          _cropRect.right,
          _cropRect.bottom + delta.dy,
        );
      case _DragMode.resizeW:
        next = Rect.fromLTRB(
          _cropRect.left + delta.dx,
          _cropRect.top,
          _cropRect.right,
          _cropRect.bottom,
        );
      case _DragMode.resizeE:
        next = Rect.fromLTRB(
          _cropRect.left,
          _cropRect.top,
          _cropRect.right + delta.dx,
          _cropRect.bottom,
        );
    }
    _cropRect = clampRect(
      rect: next,
      bounds: _imageDisplayRect,
      minSide: _minSide,
    );
  }

  // ─────────────────────────────────────────────────────────
  // 确认 / 取消
  // ─────────────────────────────────────────────────────────

  Future<void> _onConfirm() async {
    final image = _decoded;
    if (image == null || _imageDisplayRect.isEmpty || _cropRect.isEmpty) return;
    setState(() => _busy = true);
    try {
      final srcRect = mapDisplayRectToPixelRect(
        displayImageRect: _imageDisplayRect,
        displayCropRect: _cropRect,
        imagePixelSize: _imagePixelSize,
      );
      if (srcRect.width <= 0 || srcRect.height <= 0) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请调整裁剪框范围')),
        );
        return;
      }
      final cropped = await cropToPng(source: image, srcRect: srcRect);
      if (!mounted) return;
      Navigator.of(context).pop<CapturedScreenshot>(cropped);
    } on Exception {
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(const SnackBar(content: Text('裁剪失败，请重试')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _onCancel() {
    Navigator.of(context).pop<CapturedScreenshot>(null);
  }

  // ─────────────────────────────────────────────────────────
  // build
  // ─────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final paper = theme.extension<PaperColors>() ?? PaperColors.light;
    final colorScheme = theme.colorScheme;

    return PaperScaffold(
      appBar: AppBar(
        title: const Text('框选题目区域'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: _onCancel,
          tooltip: '关闭',
        ),
      ),
      body: SafeArea(
        child: _buildBody(isDark: isDark, paper: paper, colorScheme: colorScheme),
      ),
    );
  }

  Widget _buildBody({
    required bool isDark,
    required PaperColors paper,
    required ColorScheme colorScheme,
  }) {
    if (_decoding) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_loadFailed || _decoded == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.broken_image_outlined, size: 48, color: colorScheme.outline),
            const SizedBox(height: 12),
            Text('图片加载失败', style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 16),
            FilledButton.tonal(
              onPressed: _onCancel,
              child: const Text('返回'),
            ),
          ],
        ),
      );
    }
    return Column(
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              _computeContainRect(constraints);
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanStart: _onPanStart,
                onPanUpdate: _onPanUpdate,
                onPanEnd: _onPanEnd,
                child: CustomPaint(
                  size: Size.infinite,
                  painter: CropFramePainter(
                    image: _decoded!,
                    imageDisplayRect: _imageDisplayRect,
                    cropRect: _cropRect,
                    frameColor: isDark ? colorScheme.primary : paper.stampRed,
                    handleColor: paper.polaroidBg,
                    mask: isDark ? 0.62 : 0.45,
                  ),
                ),
              );
            },
          ),
        ),
        _BottomBar(
          busy: _busy,
          onCancel: _onCancel,
          onConfirm: _onConfirm,
          paper: paper,
        ),
      ],
    );
  }

  /// 手算 BoxFit.contain（图片完整、居中显示），写入 _imageDisplayRect 并初始化裁剪框。
  /// 在 LayoutBuilder 里同步调用（LayoutBuilder 重建时自动重算），无需 post-frame。
  void _computeContainRect(BoxConstraints constraints) {
    if (_decoded == null || _imagePixelSize.isEmpty) return;
    final maxW = constraints.maxWidth;
    final maxH = constraints.maxHeight;
    final iw = _imagePixelSize.width;
    final ih = _imagePixelSize.height;
    if (maxW <= 0 || maxH <= 0 || iw <= 0 || ih <= 0) return;

    final scale = math.min(maxW / iw, maxH / ih);
    final fitW = iw * scale;
    final fitH = ih * scale;
    final left = (maxW - fitW) / 2;
    final top = (maxH - fitH) / 2;
    final rect = Rect.fromLTWH(left, top, fitW, fitH);

    // 初始化/旋转重建时，若裁剪框还没就绪则设为整图。
    final needsInit = _cropRect.isEmpty || _imageDisplayRect.isEmpty;
    _imageDisplayRect = rect;
    if (needsInit) _cropRect = rect;
  }
}

/// 底部操作条：取消（左）+ 确认裁剪（右），纸感白底压条。
class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.busy,
    required this.onCancel,
    required this.onConfirm,
    required this.paper,
  });

  final bool busy;
  final VoidCallback onCancel;
  final VoidCallback onConfirm;
  final PaperColors paper;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      top: false,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        decoration: BoxDecoration(
          color: paper.polaroidBg.withValues(alpha: 0.96),
          border: Border(top: BorderSide(color: paper.ruleSoft)),
        ),
        child: Row(
          children: [
            Expanded(
              child: TextButton.icon(
                onPressed: busy ? null : onCancel,
                icon: const Icon(Icons.close, size: 18),
                label: const Text('取消'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.icon(
                onPressed: busy ? null : onConfirm,
                icon: busy
                    ? SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: theme.colorScheme.onPrimary,
                        ),
                      )
                    : const Icon(Icons.check, size: 18),
                label: Text(busy ? '裁剪中…' : '确认裁剪'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}