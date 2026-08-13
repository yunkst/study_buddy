import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final onboardingDone = prefs.getBool('onboarding_done') ?? false;
  runApp(ProviderScope(child: StudyBuddyApp(showOnboarding: !onboardingDone)));
}

/// 待处理图片 holder：分享冷启动降级用。
///
/// App 被杀后从「分享菜单」打开会传 ACTION_SEND intent，原生 MainActivity 通过
/// EventChannel(`study_buddy/share`) 在 Flutter 启动期推送 bytes。若 resume 时
/// rootNavigatorKey 上下文未就绪，[pending] 作为兜底静态字段，由 TodayPage 首帧
/// 消费弹出 AI 面板——避免在 Flutter 上下文未就绪时弹 sheet 失败。
class PendingScreenshotStore {
  static dynamic pending; // CapturedScreenshot?
}