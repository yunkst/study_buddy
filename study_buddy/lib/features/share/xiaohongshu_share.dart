import 'package:url_launcher/url_launcher.dart';

import '../../core/providers/share_card_provider.dart';
import '../../core/services/logger_service.dart';

/// 小红书没有开放第三方分享 SDK，只能用「URL Scheme 唤起 + 相册兜底」路线。
/// 本文件：生成分享文案 + 唤起小红书 App。
///
/// `xhsdiscover://` 为逆向所得的内置 scheme，可能随版本变化；未装/失败时
/// 由调用方按 [XhsOpenResult] 兜底（引导应用商店 / 打开网页版）。
enum XhsOpenResult { launched, notInstalled, failed }

/// 生成带话题标签的分享文案（供复制到剪贴板，用户在小红书发布页粘贴）。
///
/// 正文用 AI「今日收获」总结（或模板），叠加连续天数/专注/待复习数据，
/// 末尾 # 话题。最终复制内容=可读句子 + 换行 + 话题标签。
String buildShareCaption(ShareCardData data, {required String summary}) {
  final buf = StringBuffer();
  buf.write(summary);
  if (data.streak > 1) buf.write(' 已经连续打卡 ${data.streak} 天！');
  if (data.focusMinutes > 0) buf.write(' 今天专注 ${data.focusMinutes} 分钟。');
  buf.write('\n#{学习打卡} #{StudyBuddy} #{每日进步}');
  return buf.toString();
}

/// 尝试唤起小红书 App（跳发布页）。优先 `xhsdiscover://`，其次落地页兜底。
///
/// 返回 [XhsOpenResult]：
/// - launched：成功调起（不一定能确认先进到发布页，但已跳转）
/// - notFound：未检测到可处理 xhsdiscover scheme 的 App（未安装）
/// - failed：检测到但启动报错
Future<XhsOpenResult> openXiaohongshu() async {
  // 发布页常用 xhsdiscover 派生的 note 编辑入口；通用落地页作为兜底。
  const scheme = 'xhsdiscover://';
  const web = 'https://www.xiaohongshu.com';

  try {
    final uri = Uri.parse(scheme);
    final can = await canLaunchUrl(uri);
    if (!can) return XhsOpenResult.notInstalled;
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    return ok ? XhsOpenResult.launched : XhsOpenResult.failed;
  } catch (e) {
    // canLaunch/launch 平台异常（如旧 Android 无 scheme 处理）→ 网页兜底。
    LoggerService.instance.w('小红书 scheme 唤起失败,回退网页: $e',
        category: LogCategory.ui, tags: const ['xhs-share']);
    try {
      await launchUrl(Uri.parse(web), mode: LaunchMode.externalApplication);
      return XhsOpenResult.launched;
    } catch (e2) {
      LoggerService.instance.w('小红书网页兜底也失败: $e2',
          category: LogCategory.ui, tags: const ['xhs-share']);
      return XhsOpenResult.notInstalled;
    }
  }
}