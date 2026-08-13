import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

import '../../core/providers/daily_summary_provider.dart';
import '../../core/providers/share_card_provider.dart';
import '../../core/services/share_to_gallery.dart';
import '../../core/services/widget_to_image.dart';
import 'share_card_widget.dart';
import 'xiaohongshu_share.dart';

/// 分享卡预览 + 分享流程（BottomSheet）。
///
/// 流程：渲染卡片预览（统计数据秒出，AI 总结在点「分享」时才按需触发）
/// → 点分享 → 等 AI 总结落到 UI → captureWidget 截图 → 存相册 → 复制文案 → 唤起小红书。
///
/// 权限/唤起失败不阻断：相册保存失败仍复制文案；小红书未装则引导提示。
Future<void> showShareSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const _ShareSheetBody(),
  );
}

class _ShareSheetBody extends ConsumerStatefulWidget {
  const _ShareSheetBody();

  @override
  ConsumerState<_ShareSheetBody> createState() => _ShareSheetBodyState();
}

class _ShareSheetBodyState extends ConsumerState<_ShareSheetBody> {
  final GlobalKey _cardKey = GlobalKey();
  bool _sharing = false;

  @override
  Widget build(BuildContext context) {
    final dataAsync = ref.watch(shareCardDataProvider);
    // AI 总结按需：仅当数据就绪且用户点了分享才触发，触发生成。
    final data = dataAsync.value;

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        child: Container(
          constraints: const BoxConstraints(maxHeight: 520),
          decoration: const BoxDecoration(
            color: Color(0xFFF5F0E6), // 纸面底
            borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              // 顶部把手
              Container(width: 40, height: 4, decoration: BoxDecoration(color: Color(0xFFD9CFB8), borderRadius: BorderRadius.circular(2))),
              const SizedBox(height: 16),
              const Text('分享今日学习',
                  style: TextStyle(fontFamily: 'NotoSerifSC', fontSize: 17, fontWeight: FontWeight.w700, color: Color(0xFF2C2620))),
              const SizedBox(height: 12),
              Expanded(
                child: dataAsync.when(
                  loading: () => const Center(child: CircularProgressIndicator()),
                  error: (e, _) => Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text('数据加载失败: $e', textAlign: TextAlign.center),
                  ),
                  data: (d) => SingleChildScrollView(
                    child: RepaintBoundary(
                      key: _cardKey,
                      child: ShareCardWidget(data: d, date: DateTime.now()),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
                child: SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: FilledButton(
                    onPressed: _sharing ? null : () => _doShare(context, data),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFB8472D),
                      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
                    ),
                    child: _sharing
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Text('保存到相册并分享小红书',
                            style: TextStyle(fontSize: 15, fontFamily: 'NotoSansSC')),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _doShare(BuildContext context, ShareCardData? data) async {
    // 在任何 await 前捕获 messenger，避免跨越 async gap 使用 BuildContext。
    final messenger = ScaffoldMessenger.of(context);
    if (data == null) {
      messenger.showSnackBar(const SnackBar(content: Text('数据未就绪，请稍候重试')));
      return;
    }
    setState(() => _sharing = true);
    try {
      // 1. 按需触发 AI 总结并等待其落到 UI（避免截到 loading 占位）。
      final summary = await ref.read(dailySummaryProvider(data.topics).future);
      // 等一帧让 AI 文案渲染进卡。
      await WidgetsBinding.instance.endOfFrame;

      // 2. 截图。
      final bytes = await captureWidget(_cardKey, pixelRatio: 3);

      // 3. 存相册。
      final saveResult = await saveImageToGallery(bytes);

      // 4. 复制文案。
      final caption = buildShareCaption(data, summary: summary);
      await Clipboard.setData(ClipboardData(text: caption));

      switch (saveResult) {
        case SaveToGalleryResult.saved:
          messenger.showSnackBar(const SnackBar(content: Text('图片已存到相册，文案已复制 ✓')));
        case SaveToGalleryResult.permissionDenied:
          messenger.showSnackBar(
            const SnackBar(content: Text('相册权限被拒绝，请在系统设置中允许后重试')),
          );
        case SaveToGalleryResult.failed:
          messenger.showSnackBar(const SnackBar(content: Text('保存到相册失败，但文案已复制')));
      }

      // 5. 唤起小红书。
      final openResult = await openXiaohongshu();
      switch (openResult) {
        case XhsOpenResult.launched:
          break; // 已跳转，无需提示。
        case XhsOpenResult.notInstalled:
          messenger.showSnackBar(
            const SnackBar(content: Text('未检测到小红书 App，可打开图片后手动发布')),
          );
        case XhsOpenResult.failed:
          messenger.showSnackBar(
            const SnackBar(content: Text('打开小红书失败，图片已存相册可手动发布')),
          );
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('分享失败: $e')));
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }
}
