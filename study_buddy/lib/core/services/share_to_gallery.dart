import 'dart:typed_data';

import 'package:gal/gal.dart';

import 'logger_service.dart';

/// 把图片字节保存到系统相册（小红书发图需从相册取）。
///
/// 用 gal 包：自动处理 Android 10+ / iOS 的相册写入权限（scoped storage / Photos）。
/// 返回 [SaveToGalleryResult] 表达三种结果，让调用方决定反馈：
/// - saved：已保存
/// - permissionDenied：相册权限被拒，需引导去系统设置（见返回值说明）
/// - failed：保存过程出错（非权限问题，如磁盘满）
///
/// 权限拒绝不在此处弹设置引导，交由 UI 层（openAppSettings）处理，保持服务纯函数可测。
enum SaveToGalleryResult { saved, permissionDenied, failed }

/// 保存 PNG 字节到相册，文件名带时间戳避免覆盖，相册名为 StudyBuddy。
Future<SaveToGalleryResult> saveImageToGallery(Uint8List pngBytes) async {
  try {
    // Android 10+ 无需权限；此前版本需 WRITE_EXTERNAL_STORAGE（Manifest 已配 maxSdk28）。
    if (!await Gal.hasAccess()) {
      final granted = await Gal.requestAccess();
      if (!granted) return SaveToGalleryResult.permissionDenied;
    }
    await Gal.putImageBytes(
      pngBytes,
      name: 'study_buddy_${DateTime.now().millisecondsSinceEpoch}',
      album: 'StudyBuddy',
    );
    return SaveToGalleryResult.saved;
  } on GalException catch (e) {
    // 权限类错误归为 denied，其余（磁盘/编解码）归为 failed。
    if (e.type == GalExceptionType.accessDenied) {
      return SaveToGalleryResult.permissionDenied;
    }
    LoggerService.instance.e('保存图片到相册失败: ${e.type}: $e',
        category: LogCategory.ui, tags: const ['gallery-save']);
    return SaveToGalleryResult.failed;
  } catch (e) {
    LoggerService.instance.e('保存图片到相册异常: $e',
        category: LogCategory.ui, tags: const ['gallery-save']);
    return SaveToGalleryResult.failed;
  }
}