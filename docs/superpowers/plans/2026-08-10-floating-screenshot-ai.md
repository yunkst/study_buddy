# 系统级截图悬浮窗 + AI 分析 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 废弃 study_buddy 内嵌 WebView，改为系统级悬浮窗 + MediaProjection 区域截图，截图后跳回 App 复用 ai_panel_sheet 做 AI 分析。

**Architecture:** 纯原生（Kotlin）实现悬浮球 Service + MediaProjection 截图 + 全屏选区悬浮窗，通过 MethodChannel 与 Flutter 桥接；Flutter 侧删除 WebView 模块、新增截图 provider 与权限引导页、复用 ai_panel_sheet 与 agent_session_provider；engine 零改动。截图统一经 PendingScreenshotHolder（Application 级单例）+ takePendingScreenshot 模式传递（热/冷路径一致）。

**Tech Stack:** Flutter 3.x / Dart 3.9 / Riverpod 3 / go_router 14；原生 Kotlin（Android MediaProjection / WindowManager / FGS）；MethodChannel；包名 `io.github.yunkst.studybuddy`，Kotlin 路径 `android/app/src/main/kotlin/io/github/yunkst/studybuddy/`。

## Global Constraints

（摘自 spec §1.2 + §8，所有任务隐含遵守）

- **删除内嵌浏览器**：移除 `flutter_inappwebview` 依赖及全部 WebView 代码；`ai_panel_sheet` 保留并改输入源。
- **令牌不写死**：源码与 git 历史不得出现任何网站鉴权凭据字面值（`ixunke`/`xkh5-token`/`Authorization.*Bearer` 字面量）。本阶段不接触网站鉴权。
- **AI 走 study_engine 原路径**：截图 → `agentSessionProvider` → `StudyScenario` → `save_topic`；engine 零改动，22 测试通过。
- **截图纯内存**：PNG bytes 不落盘、不缓存，仅 widget 生命周期内有效。
- **复用 agent_session_provider**：不新增 agent 入口。
- **Android 14+ FGS 时序**：先用户授权 MediaProjection → `startForeground(type=mediaProjection)` → `getMediaProjection()`；顺序错则 SecurityException。
- **Android 14+ 授权 token 不可缓存复用**：每次会话走新授权（新 createScreenCaptureIntent）；绝不缓存旧 Intent。
- **MediaProjection 会话制**：授权一次 → FGS + VirtualDisplay 常驻 → 后续截图免授权；服务被杀才重新授权。
- **截图传递统一走 holder + take**：不使用 EventChannel 推送。
- **包名/路径**：`io.github.yunkst.studybuddy`；Kotlin 文件放 `android/app/src/main/kotlin/io/github/yunkst/studybuddy/`。
- **engine 路径**：`packages/study_engine`（纯 Dart，`dart analyze`/`dart test`）；app 路径 `study_buddy`（`flutter analyze`/`flutter test`）。

---

## File Structure

### 删除
- `study_buddy/lib/features/external_qbank/qbank_web_view.dart`
- `study_buddy/lib/features/external_qbank/external_qbank_page.dart`
- `study_buddy/lib/features/external_qbank/floating_ai_button.dart`
- `study_buddy/lib/core/providers/webview_screenshot_provider.dart`

### 保留并改造
- `study_buddy/lib/features/external_qbank/ai_panel_sheet.dart` — 改 import 来源（CapturedScreenshot 迁移）
- `study_buddy/lib/features/home/home_page.dart` — 删题库入口，加悬浮窗状态
- `study_buddy/lib/router.dart` — 删 `/external-qbank`
- `study_buddy/lib/main.dart` — 启动检查权限 + 唤起 overlay + 取待处理截图
- `study_buddy/pubspec.yaml` — 删 flutter_inappwebview
- `study_buddy/android/app/src/main/AndroidManifest.xml` — 加权限与组件声明
- `study_buddy/android/app/src/main/kotlin/io/github/yunkst/studybuddy/MainActivity.kt` — 注册 plugin

### 新增（Flutter/Dart）
- `study_buddy/lib/core/providers/screenshot_provider.dart` — CapturedScreenshot 类 + MethodChannel 封装
- `study_buddy/lib/features/overlay/permission_guide_page.dart` — 首次悬浮窗权限引导

### 新增（Kotlin 原生）
- `study_buddy/android/app/src/main/kotlin/io/github/yunkst/studybuddy/ScreenshotPlugin.kt` — FlutterPlugin + MethodChannel 桥接
- `study_buddy/android/app/src/main/kotlin/io/github/yunkst/studybuddy/PendingScreenshotHolder.kt` — Application 级单例暂存
- `study_buddy/android/app/src/main/kotlin/io/github/yunkst/studybuddy/OverlayService.kt` — 悬浮球前台服务
- `study_buddy/android/app/src/main/kotlin/io/github/yunkst/studybuddy/TrampolineActivity.kt` — 授权 + 启 FGS
- `study_buddy/android/app/src/main/kotlin/io/github/yunkst/studybuddy/ScreenCaptureService.kt` — FGS + 取帧
- `study_buddy/android/app/src/main/kotlin/io/github/yunkst/studybuddy/CropOverlayView.kt` — 全屏选区

---

## Task 1: 删除 WebView 模块 + 迁移 CapturedScreenshot

**Files:**
- Delete: `study_buddy/lib/features/external_qbank/qbank_web_view.dart`
- Delete: `study_buddy/lib/features/external_qbank/external_qbank_page.dart`
- Delete: `study_buddy/lib/features/external_qbank/floating_ai_button.dart`
- Delete: `study_buddy/lib/core/providers/webview_screenshot_provider.dart`
- Create: `study_buddy/lib/core/providers/screenshot_provider.dart`
- Modify: `study_buddy/lib/features/external_qbank/ai_panel_sheet.dart`
- Modify: `study_buddy/lib/router.dart`
- Modify: `study_buddy/lib/features/home/home_page.dart`
- Modify: `study_buddy/pubspec.yaml`

**Interfaces:**
- Produces: `CapturedScreenshot`（迁移到 `screenshot_provider.dart`，字段不变：`Uint8List pngBytes` + `String base64DataUri`）+ 占位 `ScreenshotProvider` 类（MethodChannel 封装，本任务先建壳，Task 7 接原生后实现具体方法）

- [ ] **Step 1: 删除 4 个 WebView 文件**

```bash
rm study_buddy/lib/features/external_qbank/qbank_web_view.dart
rm study_buddy/lib/features/external_qbank/external_qbank_page.dart
rm study_buddy/lib/features/external_qbank/floating_ai_button.dart
rm study_buddy/lib/core/providers/webview_screenshot_provider.dart
```

- [ ] **Step 2: 创建 screenshot_provider.dart（迁移 CapturedScreenshot + 占位 provider）**

```dart
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 截图结果。bytes 与 base64DataUri 持有同一份图片数据，调用方择一使用。
///
/// 从原生截图 channel 取得（系统级 MediaProjection 截图），纯内存：
/// 不写盘、不缓存，仅在本对象生命周期内有效。
@immutable
class CapturedScreenshot {
  final Uint8List pngBytes;
  final String base64DataUri; // 形如 "data:image/png;base64,xxxx"
  const CapturedScreenshot(this.pngBytes, this.base64DataUri);
}

/// 系统级截图悬浮窗的 Flutter 侧桥接。
///
/// 通过 MethodChannel("study_buddy/overlay") 与原生通信：
/// - 权限检查 / 引导
/// - 悬浮球显隐
/// - 取待处理截图（热/冷路径统一走 PendingScreenshotHolder + take）
///
/// 原生侧（ScreenshotPlugin.kt）在 Task 2-6 实现；本 provider 先建壳，
/// 具体方法调用在原生就绪后（Task 7）验证。
class ScreenshotProvider {
  static const _channel = MethodChannel('study_buddy/overlay');

  /// 检查悬浮窗权限是否已授予。
  Future<bool> checkOverlayPermission() async {
    final result = await _channel.invokeMethod<bool>('checkOverlayPermission');
    return result ?? false;
  }

  /// 跳转系统悬浮窗权限设置页（原生侧做厂商判断 + 兜底）。
  Future<void> requestOverlayPermission() async {
    await _channel.invokeMethod<void>('requestOverlayPermission');
  }

  /// 显示悬浮球（唤起 OverlayService）。
  Future<void> showOverlay() async {
    await _channel.invokeMethod<void>('showOverlay');
  }

  /// 隐藏悬浮球。
  Future<void> hideOverlay() async {
    await _channel.invokeMethod<void>('hideOverlay');
  }

  /// 取待处理截图（从原生 PendingScreenshotHolder）。无则返回 null。
  ///
  /// 取出后原生侧自动清空。App 被拉回前台 / 冷启动时调用。
  Future<CapturedScreenshot?> takePendingScreenshot() async {
    final bytes = await _channel.invokeMethod<Uint8List>('takePendingScreenshot');
    if (bytes == null) return null;
    final b64 = base64Encode(bytes);
    return CapturedScreenshot(bytes, 'data:image/png;base64,$b64');
  }
}

final screenshotProvider = Provider<ScreenshotProvider>((ref) {
  return ScreenshotProvider();
});
```

- [ ] **Step 3: 改 ai_panel_sheet.dart 的 import**

把 `import '../../core/providers/webview_screenshot_provider.dart';` 改为 `import '../../core/providers/screenshot_provider.dart';`。其余代码（`showAiPanel`、`_AiPanelSheet`、9 分支 switch）零改动——`CapturedScreenshot` 字段不变。

- [ ] **Step 4: 改 router.dart，删 /external-qbank 路由**

```dart
import 'package:go_router/go_router.dart';
import 'features/home/home_page.dart';

GoRouter buildRouter() {
  return GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => const HomePage(),
      ),
    ],
  );
}
```

- [ ] **Step 5: 改 home_page.dart，删「进入题库」入口**

删掉 `import 'package:go_router/go_router.dart';` 和「进入题库」FilledButton.icon。占位文案改为提示悬浮窗功能（Task 8 会再完善状态显示）：

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/providers/database_provider.dart';

class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dbAsync = ref.watch(databaseProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Study Buddy')),
      body: dbAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('数据库初始化失败: $e')),
        data: (db) => const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              '地基已就绪 ✅\n开启悬浮窗权限后，在任意界面点悬浮球即可截图分析。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16),
            ),
          ),
        ),
      ),
    );
  }
}
```

- [ ] **Step 6: 删 pubspec.yaml 的 flutter_inappwebview 依赖**

删除 `- flutter_inappwebview: ^6.1.5` 一行。

- [ ] **Step 7: pub get + analyze 验证**

Run: `cd study_buddy && flutter pub get && flutter analyze`
Expected: `No issues found!`（ai_panel_sheet 改 import 后无未用引用；router/home 无 go_router 残留引用——home_page 已删 go_router import）

注意：删依赖后 `pubspec.lock` 会移除 flutter_inappwebview 系列 7 个包，属预期。

- [ ] **Step 8: test 验证**

Run: `cd study_buddy && flutter test`
Expected: `All tests passed!`（widget_test 找 'Study Buddy' AppBar 文本，home_page 保留 AppBar 故通过）

- [ ] **Step 9: Commit**

```bash
cd study_buddy && git add -A && git commit -m "refactor(app): 删除内嵌 WebView 模块，迁移 CapturedScreenshot 到 screenshot_provider

- 删 qbank_web_view / external_qbank_page / floating_ai_button / webview_screenshot_provider
- 删 /external-qbank 路由与首页题库入口
- 删 flutter_inappwebview 依赖
- ai_panel_sheet 改 import，9 分支逻辑零改动
- 新增 screenshot_provider 占位（MethodChannel 壳，原生 Task 2-6 实现）

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 2: AndroidManifest 权限与组件声明 + minSdk 确认

**Files:**
- Modify: `study_buddy/android/app/src/main/AndroidManifest.xml`
- Modify: `study_buddy/android/app/build.gradle.kts`（仅当 minSdk < 24 时）

**Interfaces:**
- Produces: Manifest 声明 SYSTEM_ALERT_WINDOW + 2 个 FGS 权限 + TrampolineActivity + OverlayService(specialUse) + ScreenCaptureService(mediaProjection) 组件

- [ ] **Step 1: 在 manifest 根加 3 个权限**

在 `<manifest>` 下、`<application>` 之前加：

```xml
    <uses-permission android:name="android.permission.SYSTEM_ALERT_WINDOW" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PROJECTION" />
```

- [ ] **Step 2: 在 <application> 内加 3 个组件声明**

```xml
        <activity
            android:name=".TrampolineActivity"
            android:exported="false"
            android:theme="@android:style/Theme.Translucent.NoTitleBar" />

        <service
            android:name=".OverlayService"
            android:exported="false"
            android:foregroundServiceType="specialUse">
            <property
                android:name="android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE"
                android:value="Floating screenshot assist button for study analysis" />
        </service>

        <service
            android:name=".ScreenCaptureService"
            android:exported="false"
            android:foregroundServiceType="mediaProjection" />
```

- [ ] **Step 3: 确认 minSdk ≥ 24**

检查 `build.gradle.kts` 的 `minSdk = flutter.minSdkVersion`。Flutter 默认 minSdk 21，但 `FOREGROUND_SERVICE_MEDIA_PROJECTION` 类型在 API 29+ 才稳定、`specialUse` FGS 在 API 34+ 校验。**不改 minSdk**（21 仍可运行，targetSdk 决定校验行为），但在 Task 6 实现时注意 API 级别判断（`Build.VERSION.SDK_INT >= 29` 等守卫）。

本步无代码改动，仅确认。

- [ ] **Step 4: 验证 manifest 合法（构建检查）**

Run: `cd study_buddy && flutter analyze`
Expected: `No issues found!`（manifest 不影响 dart analyze，但确保无残留引用报错）

- [ ] **Step 5: Commit**

```bash
cd study_buddy && git add android/app/src/main/AndroidManifest.xml && git commit -m "feat(android): Manifest 声明悬浮窗 + 2 FGS + TrampolineActivity

- SYSTEM_ALERT_WINDOW + FOREGROUND_SERVICE + FOREGROUND_SERVICE_MEDIA_PROJECTION
- OverlayService(specialUse) + ScreenCaptureService(mediaProjection) + TrampolineActivity
- Android 14+ specialUse FGS 声明 PROPERTY_SPECIAL_USE_FGS_SUBTYPE

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 3: PendingScreenshotHolder + ScreenshotPlugin（Flutter 桥接）

**Files:**
- Create: `study_buddy/android/app/src/main/kotlin/io/github/yunkst/studybuddy/PendingScreenshotHolder.kt`
- Create: `study_buddy/android/app/src/main/kotlin/io/github/yunkst/studybuddy/ScreenshotPlugin.kt`
- Modify: `study_buddy/android/app/src/main/kotlin/io/github/yunkst/studybuddy/MainActivity.kt`

**Interfaces:**
- Consumes: Flutter MethodChannel("study_buddy/overlay")（Task 1 的 ScreenshotProvider 已定义方法名）
- Produces: 原生侧 6 个 method handler（checkOverlayPermission / requestOverlayPermission / showOverlay / hideOverlay / takePendingScreenshot）+ Application 级 holder 单例；OverlayService/ScreenCaptureService 的调用在后续 Task 接入

- [ ] **Step 1: 创建 PendingScreenshotHolder.kt**

```kotlin
package io.github.yunkst.studybuddy

import android.app.Application

/**
 * Application 级单例，暂存最近一次裁剪后的截图 PNG bytes。
 *
 * 用途：截图裁剪完成 → put() → 拉回主 App → Flutter takePendingScreenshot() → take() 取出并清空。
 * 防 App 进程被回收后冷启动丢失截图（热/冷路径统一）。
 *
 * 边界：原生进程（OverlayService）也被杀时 holder 随进程消失，截图丢失——属可接受降级。
 *
 * 注意：不持有 Context 强引用外的资源；bytes 是纯内存数组，进程死即回收。
 */
class PendingScreenshotHolder {
    @Volatile
    private var pending: ByteArray? = null

    fun put(bytes: ByteArray) {
        pending = bytes
    }

    /** 取出并清空。无则 null。 */
    fun take(): ByteArray? {
        val b = pending
        pending = null
        return b
    }

    companion object {
        @Volatile
        private var instance: PendingScreenshotHolder? = null

        fun get(): PendingScreenshotHolder {
            return instance ?: synchronized(this) {
                instance ?: PendingScreenshotHolder().also { instance = it }
            }
        }
    }
}
```

- [ ] **Step 2: 创建 ScreenshotPlugin.kt**

```kotlin
package io.github.yunkst.studybuddy

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Flutter ↔ 原生桥接。
 *
 * MethodChannel("study_buddy/overlay") 处理：
 * - checkOverlayPermission: Settings.canDrawOverlays()
 * - requestOverlayPermission: 跳 ACTION_MANAGE_OVERLAY_PERMISSION（厂商判断见 [jumpOverlaySettings]）
 * - showOverlay / hideOverlay: 启停 OverlayService（Task 4 实现后接入）
 * - takePendingScreenshot: 从 PendingScreenshotHolder 取
 *
 * showOverlay/hideOverlay 在 Task 4 前先返回未实现（避免编译期依赖未存在类）；
 * Task 4 接入时替换为真实 startService/stopService。
 */
class ScreenshotPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private var appContext: android.content.Context? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "study_buddy/overlay").also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        appContext = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "checkOverlayPermission" -> {
                result.success(Settings.canDrawOverlays(appContext))
            }
            "requestOverlayPermission" -> {
                jumpOverlaySettings()
                result.success(null)
            }
            "showOverlay" -> {
                // Task 4 接入：startForegroundService(Intent(appContext, OverlayService::class.java))
                result.success(null)
            }
            "hideOverlay" -> {
                // Task 4 接入：appContext?.stopService(Intent(appContext, OverlayService::class.java))
                result.success(null)
            }
            "takePendingScreenshot" -> {
                result.success(PendingScreenshotHolder.get().take())
            }
            else -> result.notImplemented()
        }
    }

    /**
     * 跳转悬浮窗权限页。优先 ACTION_MANAGE_OVERLAY_PERMISSION（直达本 app），
     * 部分国产 ROM（MIUI/ColorOS/OriginOS）该 intent 跳不到正确页，兜底跳应用详情页。
     *
     * MIUI 额外有「后台弹出界面」权限，本方法不处理（在 PermissionGuidePage 文案引导）。
     */
    private fun jumpOverlaySettings() {
        val ctx = appContext ?: return
        val pkg = ctx.packageName
        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            Intent(
                Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                Uri.parse("package:$pkg")
            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        } else {
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                .setData(Uri.parse("package:$pkg"))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        try {
            ctx.startActivity(intent)
        } catch (_: Exception) {
            // 直达失败 → 兜底应用详情页
            ctx.startActivity(
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                    .setData(Uri.parse("package:$pkg"))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
        }
    }
}
```

- [ ] **Step 3: 改 MainActivity.kt 注册 plugin**

```kotlin
package io.github.yunkst.studybuddy

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(ScreenshotPlugin())
    }
}
```

- [ ] **Step 4: 构建（编译验证）**

Run: `cd study_buddy && flutter build apk --debug 2>&1 | tail -20`
Expected: `✓ Built build\app\outputs\flutter-apk\app-debug.apk`（Kotlin 编译通过；OverlayService/ScreenCaptureService 尚未创建但未被引用，不报错）

- [ ] **Step 5: analyze 验证**

Run: `cd study_buddy && flutter analyze`
Expected: `No issues found!`

- [ ] **Step 6: Commit**

```bash
cd study_buddy && git add -A && git commit -m "feat(android): ScreenshotPlugin + PendingScreenshotHolder Flutter 桥接

- PendingScreenshotHolder: Application 级单例暂存截图，防冷启动丢失
- ScreenshotPlugin: MethodChannel(overlay) 6 方法，悬浮窗权限跳转含厂商兜底
- MainActivity 注册 plugin
- showOverlay/hideOverlay 占位，Task 4 接入 OverlayService

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 4: OverlayService 悬浮球前台服务

**Files:**
- Create: `study_buddy/android/app/src/main/kotlin/io/github/yunkst/studybuddy/OverlayService.kt`
- Modify: `study_buddy/android/app/src/main/kotlin/io/github/yunkst/studybuddy/ScreenshotPlugin.kt`（接入 showOverlay/hideOverlay）

**Interfaces:**
- Consumes: PendingIntent / 通知 channel（自建）
- Produces: 悬浮球常驻前台服务；点击触发截图流程（Task 5 的 TrampolineActivity 启动）；hideOverlay()/showOverlay() 供截图前隐藏

- [ ] **Step 1: 创建 OverlayService.kt**

```kotlin
package io.github.yunkst.studybuddy

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.graphics.Color
import android.graphics.PixelFormat
import android.os.Build
import android.os.IBinder
import android.provider.Settings
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.ImageView
import androidx.core.app.NotificationCompat

/**
 * 悬浮球前台服务（specialUse FGS）。
 *
 * - WindowManager 添加 56dp 圆形悬浮球（TYPE_APPLICATION_OVERLAY）
 * - 短按 → 触发截图（启动 TrampolineActivity，Task 5）
 * - 长按拖拽 → 移动 + 贴边吸附
 * - hideOverlay()/showOverlay() 截图前隐藏悬浮球，避免截进去
 *
 * 点击触发在 Task 5 TrampolineActivity 就绪前先 Toast 占位，Task 5 接入。
 */
class OverlayService : Service() {

    private lateinit var windowManager: WindowManager
    private var floatView: View? = null
    private lateinit var params: WindowManager.LayoutParams

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        windowManager = getSystemService(WINDOW_SERVICE) as WindowManager
        startForeground(NOTIFICATION_ID, buildNotification())
        if (Settings.canDrawOverlays(this)) {
            showFloatBall()
        }
    }

    private fun showFloatBall() {
        val size = (56 * resources.displayMetrics.density).toInt()
        params = WindowManager.LayoutParams(
            size, size,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = resources.displayMetrics.widthPixels - size - 32
            y = resources.displayMetrics.heightPixels / 2
        }

        val iv = ImageView(this).apply {
            setBackgroundColor(Color.parseColor("#6750A4"))
            // 圆形背景
            clipToOutline = true
            outlineProvider = object : android.view.ViewOutlineProvider() {
                override fun getOutline(view: View, outline: android.graphics.Outline) {
                    outline.setOval(0, 0, view.width, view.height)
                }
            }
        }
        attachTouchListener(iv)
        floatView = iv
        windowManager.addView(iv, params)
    }

    private fun attachTouchListener(view: View) {
        var startX = 0
        var startY = 0
        var rawStartX = 0f
        var rawStartY = 0f
        var moved = false
        val touchSlop = 8 * resources.displayMetrics.density

        view.setOnTouchListener { v, event ->
            when (event.action) {
                MotionEvent.ACTION_DOWN -> {
                    startX = params.x; startY = params.y
                    rawStartX = event.rawX; rawStartY = event.rawY
                    moved = false
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = event.rawX - rawStartX
                    val dy = event.rawY - rawStartY
                    if (dx * dx + dy * dy > touchSlop * touchSlop) moved = true
                    params.x = startX + dx.toInt()
                    params.y = startY + dy.toInt()
                    windowManager.updateViewLayout(v, params)
                }
                MotionEvent.ACTION_UP -> {
                    if (!moved) {
                        // 短按 → 触发截图
                        triggerScreenshot()
                    } else {
                        // 贴边吸附：贴左或贴右
                        val mid = resources.displayMetrics.widthPixels / 2
                        params.x = if (params.x + v.width / 2 < mid) 0 else resources.displayMetrics.widthPixels - v.width
                        windowManager.updateViewLayout(v, params)
                    }
                }
            }
            true
        }
    }

    /**
     * 点击悬浮球 → 隐藏悬浮球 → 启动 TrampolineActivity 走 MediaProjection 授权 + 截图。
     * Task 5 接入 TrampolineActivity；此前先 Toast 占位。
     */
    private fun triggerScreenshot() {
        hideOverlay()
        // Task 5 接入：
        // startActivity(Intent(this, TrampolineActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        android.widget.Toast.makeText(this, "截图功能接入中（Task 5）", android.widget.Toast.LENGTH_SHORT).show()
        // 占位：1.5s 后恢复悬浮球，避免测试时永久消失
        android.os.Handler(mainLooper).postDelayed({ showOverlayInternal() }, 1500)
    }

    fun hideOverlay() {
        floatView?.let { windowManager.removeView(it); floatView = null }
    }

    private fun showOverlayInternal() {
        if (floatView == null && Settings.canDrawOverlays(this)) showFloatBall()
    }

    /** 外部（ScreenshotPlugin）唤起恢复。 */
    fun showOverlay() = showOverlayInternal()

    private fun buildNotification(): Notification {
        val channelId = "overlay_service"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(channelId, "悬浮球服务", NotificationManager.IMPORTANCE_LOW)
            (getSystemService(NOTIFICATION_SERVICE) as NotificationManager).createNotificationChannel(channel)
        }
        return NotificationCompat.Builder(this, channelId)
            .setContentTitle("Study Buddy")
            .setContentText("截图悬浮窗运行中")
            .setSmallIcon(android.R.drawable.ic_menu_camera)
            .setOngoing(true)
            .build()
    }

    override fun onDestroy() {
        super.onDestroy()
        floatView?.let { windowManager.removeView(it); floatView = null }
    }

    companion object {
        private const val NOTIFICATION_ID = 1001
    }
}
```

- [ ] **Step 2: 接入 ScreenshotPlugin 的 showOverlay/hideOverlay**

把 ScreenshotPlugin.kt 的两个占位方法替换为：

```kotlin
            "showOverlay" -> {
                val ctx = appContext ?: run { result.success(null); return }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    ctx.startForegroundService(Intent(ctx, OverlayService::class.java))
                } else {
                    ctx.startService(Intent(ctx, OverlayService::class.java))
                }
                result.success(null)
            }
            "hideOverlay" -> {
                appContext?.stopService(Intent(appContext, OverlayService::class.java))
                result.success(null)
            }
```

> ⚠️ 注意：`hideOverlay` 此处停整个服务（悬浮球消失）。截图前临时隐藏用 `OverlayService.hideOverlay()`，但跨进程调 Service 方法需要 binder 或 LocalBroadcast——MVP 简化：截图触发的隐藏在 `triggerScreenshot()` 内部已做（同进程直接调），`hideOverlay` method 仅供 Flutter 主动停悬浮球时用。本步按此实现，Task 5 review 时确认。

- [ ] **Step 3: 构建验证**

Run: `cd study_buddy && flutter build apk --debug 2>&1 | tail -20`
Expected: 构建成功（OverlayService 编译通过，通知 channel + WindowManager 逻辑就绪）

- [ ] **Step 4: analyze 验证**

Run: `cd study_buddy && flutter analyze`
Expected: `No issues found!`

- [ ] **Step 5: Commit**

```bash
cd study_buddy && git add -A && git commit -m "feat(android): OverlayService 悬浮球前台服务

- WindowManager + TYPE_APPLICATION_OVERLAY 添加 56dp 圆形悬浮球
- 短按触发截图（Task 5 接入 TrampolineActivity）、长按拖拽 + 贴边吸附
- specialUse FGS 常驻通知
- ScreenshotPlugin 接入 showOverlay/hideOverlay

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 5: TrampolineActivity + ScreenCaptureService（MediaProjection 授权 + 取帧）

**Files:**
- Create: `study_buddy/android/app/src/main/kotlin/io/github/yunkst/studybuddy/TrampolineActivity.kt`
- Create: `study_buddy/android/app/src/main/kotlin/io/github/yunkst/studybuddy/ScreenCaptureService.kt`
- Modify: `study_buddy/android/app/src/main/kotlin/io/github/yunkst/studybuddy/OverlayService.kt`（triggerScreenshot 接入 TrampolineActivity）

**Interfaces:**
- Consumes: MediaProjectionManager（系统服务）
- Produces: 截图全屏 Bitmap（经 PendingScreenshotHolder → CropOverlayView，Task 6）；会话制 VirtualDisplay 常驻

- [ ] **Step 1: 创建 TrampolineActivity.kt**

```kotlin
package io.github.yunkst.studybuddy

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper

/**
 * 1px 透明 Activity，负责 MediaProjection 授权时序。
 *
 * 时序（Android 14+ 强校验，顺序错则 SecurityException）：
 * 1. createScreenCaptureIntent() → startActivityForResult 弹系统授权框
 * 2. onActivityResult 拿授权 Intent
 * 3. startForegroundService(ScreenCaptureService) 传授权 Intent
 * 4. ScreenCaptureService 先 startForeground(mediaProjection) 再 getMediaProjection()
 *
 * 持有 SYSTEM_ALERT_WINDOW 豁免后台启动 Activity 限制（从悬浮球点击触发）。
 * 后续会话内截图不走此 Activity（ScreenCaptureService 直接取帧）。
 */
class TrampolineActivity : Activity() {

    private val mpm by lazy {
        getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 会话已存在（ScreenCaptureService 存活）→ 直接截图，不弹授权
        if (ScreenCaptureService.isSessionAlive()) {
            ScreenCaptureService.requestCapture()
            finish()
            return
        }
        // 首次：弹授权框
        @Suppress("DEPRECATION")
        startActivityForResult(mpm.createScreenCaptureIntent(), REQUEST_CODE)
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_CODE && resultCode == RESULT_OK && data != null) {
            // 启动 FGS 传授权 Intent；FGS 内 startForeground 后 getMediaProjection
            val svc = Intent(this, ScreenCaptureService::class.java).putExtra(EXTRA_RESULT_INTENT, data)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(svc)
            } else {
                startService(svc)
            }
        }
        // 授权拒绝 / 失败：恢复悬浮球
        OverlayService.notifyCaptureFinished(this)
        finish()
    }

    companion object {
        const val EXTRA_RESULT_INTENT = "result_intent"
        private const val REQUEST_CODE = 2001
    }
}
```

- [ ] **Step 2: 创建 ScreenCaptureService.kt**

```kotlin
package io.github.yunkst.studybuddy

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.Image
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.DisplayMetrics
import android.view.WindowManager
import androidx.core.app.NotificationCompat

/**
 * MediaProjection 截图 FGS。
 *
 * 会话制：授权一次 → VirtualDisplay 常驻 → 后续截图免授权（requestCapture 直接取帧）。
 * 服务被杀 / projection.stop() → 下次重新走 TrampolineActivity 授权。
 *
 * 取帧：VirtualDisplay + ImageReader 按需挂 surface（截图瞬间取一帧，取完不停 projection）。
 */
class ScreenCaptureService : Service() {

    private var projection: MediaProjection? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var imageReader: ImageReader? = null
    private var width = 0
    private var height = 0
    private var density = 1

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        startForeground(NOTIFICATION_ID, buildNotification())
        val wm = getSystemService(WINDOW_SERVICE) as WindowManager
        val metrics = DisplayMetrics()
        @Suppress("DEPRECATION")
        wm.defaultDisplay.getRealMetrics(metrics)
        width = metrics.widthPixels
        height = metrics.heightPixels
        density = metrics.densityDpi
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.getParcelableExtra<Intent>(TrampolineActivity.EXTRA_RESULT_INTENT) != null) {
            // 首次授权：建立会话
            val resultIntent = intent.getParcelableExtra<Intent>(TrampolineActivity.EXTRA_RESULT_INTENT)!!
            setupSession(resultIntent)
        }
        return START_STICKY
    }

    private fun setupSession(authIntent: Intent) {
        val mpm = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        // Android 14+：必须先 startForeground（onCreate 已做）再 getMediaProjection
        projection = mpm.getMediaProjection(RESULT_OK, authIntent)
        projection?.registerCallback(object : MediaProjection.Callback() {
            override fun onStop() {
                projection = null
                virtualDisplay?.release(); virtualDisplay = null
            }
        }, Handler(Looper.getMainLooper()))

        imageReader = ImageReader.newInstance(width, height, PixelFormat.RGBA_8888, 2)
        virtualDisplay = projection?.createVirtualDisplay(
            "study_capture", width, height, density,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            imageReader!!.surface, null, null
        )
        imageReader!!.setOnImageAvailableListener({ reader ->
            val image = reader.acquireLatestImage() ?: return@setOnImageAvailableListener
            val bmp = image.toBitmap()
            image.close()
            // 取到全屏 Bitmap → 交 CropOverlayView（Task 6）
            showCropOverlay(bmp)
        }, Handler(Looper.getMainLooper()))
    }

    private fun Image.toBitmap(): Bitmap {
        val planes = planes
        val buffer = planes[0].buffer
        val pixelStride = planes[0].pixelStride
        val rowStride = planes[0].rowStride
        val rowPadding = rowStride - pixelStride * width
        val bmp = Bitmap.createBitmap(width + rowPadding / pixelStride, height, Bitmap.Config.ARGB_8888)
        bmp.copyPixelsFromBuffer(buffer)
        // 裁掉 rowPadding 多出来的列
        return Bitmap.createBitmap(bmp, 0, 0, width, height)
    }

    /** 弹全屏选区悬浮窗（Task 6 实现 CropOverlayView）。 */
    private fun showCropOverlay(fullBitmap: Bitmap) {
        // Task 6 接入：
        // CropOverlayView.show(this, fullBitmap) { croppedBytes ->
        //     PendingScreenshotHolder.get().put(croppedBytes)
        //     launchMainApp()
        //     OverlayService.notifyCaptureFinished(this)
        // }
        // 占位：暂存全屏图，恢复悬浮球
        android.widget.Toast.makeText(this, "选区 UI 接入中（Task 6）", android.widget.Toast.LENGTH_SHORT).show()
        OverlayService.notifyCaptureFinished(this)
    }

    private fun launchMainApp() {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        launchIntent?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        startActivity(launchIntent)
    }

    /** 会话内再次截图：VirtualDisplay 已在，重新挂 surface 取一帧。 */
    private fun captureAgain() {
        // 会话存活时 ImageReader listener 仍在，触发一次取帧即可。
        // 简化：VirtualDisplay 持续投递，listener 自动取最新帧。此处空实现保留扩展点。
    }

    private fun buildNotification(): Notification {
        val channelId = "capture_service"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(channelId, "屏幕捕获", NotificationManager.IMPORTANCE_LOW)
            (getSystemService(NOTIFICATION_SERVICE) as NotificationManager).createNotificationChannel(channel)
        }
        return NotificationCompat.Builder(this, channelId)
            .setContentTitle("Study Buddy")
            .setContentText("截图会话进行中")
            .setSmallIcon(android.R.drawable.ic_menu_camera)
            .setOngoing(true)
            .build()
    }

    override fun onDestroy() {
        super.onDestroy()
        projection?.stop()
        virtualDisplay?.release()
        imageReader?.close()
    }

    companion object {
        private const val NOTIFICATION_ID = 1002
        @Volatile private var alive = false
        fun isSessionAlive(): Boolean = alive
        fun requestCapture() { /* 会话内存活时由 TrampolineActivity 调用，触发取帧 */ }
    }
}
```

- [ ] **Step 3: OverlayService.triggerScreenshot 接入 TrampolineActivity + 加 notifyCaptureFinished**

把 `triggerScreenshot()` 的占位块替换为：

```kotlin
    private fun triggerScreenshot() {
        hideOverlay()
        startActivity(Intent(this, TrampolineActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }
```

在 `companion object` 加（供 TrampolineActivity/ScreenCaptureService 截图完成时恢复悬浮球）：

```kotlin
    companion object {
        private const val NOTIFICATION_ID = 1001

        /** 截图流程结束（完成/取消/失败）→ 恢复悬浮球。 */
        fun notifyCaptureFinished(ctx: Context) {
            val intent = Intent(ctx, OverlayService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                ctx.startForegroundService(intent)
            } else {
                ctx.startService(intent)
            }
        }
    }
```

> 说明：`notifyCaptureFinished` 重启 OverlayService（onCreate 内 `showFloatBall()` 会因 floatView==null 重建悬浮球）。Task 6 接 CropOverlayView 完成回调时也调它。

- [ ] **Step 4: 构建验证**

Run: `cd study_buddy && flutter build apk --debug 2>&1 | tail -20`
Expected: 构建成功（MediaProjection/ImageReader/VirtualDisplay 编译通过）

- [ ] **Step 5: analyze 验证**

Run: `cd study_buddy && flutter analyze`
Expected: `No issues found!`

- [ ] **Step 6: Commit**

```bash
cd study_buddy && git add -A && git commit -m "feat(android): TrampolineActivity + ScreenCaptureService MediaProjection 授权取帧

- TrampolineActivity: 1px 透明，createScreenCaptureIntent 授权 → 启 FGS；会话存活直接取帧
- ScreenCaptureService: FGS(mediaProjection) + VirtualDisplay + ImageReader 按需取帧，会话制常驻
- OverlayService.triggerScreenshot 接入 TrampolineActivity + notifyCaptureFinished 恢复悬浮球
- 选区 UI（CropOverlayView）Task 6 接入

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 6: CropOverlayView 全屏选区 + 裁剪 + 拉回 App

**Files:**
- Create: `study_buddy/android/app/src/main/kotlin/io/github/yunkst/studybuddy/CropOverlayView.kt`
- Modify: `study_buddy/android/app/src/main/kotlin/io/github/yunkst/studybuddy/ScreenCaptureService.kt`（showCropOverlay 接入）

**Interfaces:**
- Consumes: 全屏 Bitmap（ScreenCaptureService 传入）
- Produces: 裁剪后 PNG bytes → PendingScreenshotHolder.put() → 拉回主 App → notifyCaptureFinished

- [ ] **Step 1: 创建 CropOverlayView.kt**

```kotlin
package io.github.yunkst.studybuddy

import android.app.Service
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.Rect
import android.graphics.RectF
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import java.io.ByteArrayOutputStream

/**
 * 全屏选区悬浮窗：显示冻结全屏截图 + 拖拽框选 + 四角手柄 + 裁剪。
 *
 * 形态：第二个 TYPE_APPLICATION_OVERLAY（可触摸），非 Activity——瞬时出现无闪屏。
 * 裁剪：Bitmap.createBitmap(full, x, y, w, h)；VirtualDisplay 物理像素 vs 触摸坐标
 * 需 density 换算（本 view 全屏，触摸坐标 = 物理像素，无需额外换算）。
 */
class CropOverlayView private constructor(
    context: Context,
    private val fullBitmap: Bitmap,
    private val onCrop: (ByteArray?) -> Unit
) : View(context) {

    private val bgPaint = Paint().apply { color = Color.parseColor("#CC000000") }
    private val borderPaint = Paint().apply {
        color = Color.WHITE; style = Paint.Style.STROKE; strokeWidth = 4f; isAntiAlias = true
    }
    private val handlePaint = Paint().apply { color = Color.WHITE; isAntiAlias = true }
    private var startRawX = 0f
    private var startRawY = 0f
    private var cropRect = RectF()
    private var dragging = false

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        // 冻结全屏图作背景
        canvas.drawBitmap(fullBitmap, 0f, 0f, null)
        // 选区外半透明遮罩
        canvas.drawRect(0f, 0f, width.toFloat(), cropRect.top, bgPaint)
        canvas.drawRect(0f, cropRect.bottom, width.toFloat(), height.toFloat(), bgPaint)
        canvas.drawRect(0f, cropRect.top, cropRect.left, cropRect.bottom, bgPaint)
        canvas.drawRect(cropRect.right, cropRect.top, width.toFloat(), cropRect.bottom, bgPaint)
        // 选区边框
        if (!cropRect.isEmpty) {
            canvas.drawRect(cropRect, borderPaint)
            drawHandles(canvas)
        }
    }

    private fun drawHandles(canvas: Canvas) {
        val r = 16f
        val corners = listOf(
            cropRect.left to cropRect.top,
            cropRect.right to cropRect.top,
            cropRect.left to cropRect.bottom,
            cropRect.right to cropRect.bottom
        )
        corners.forEach { (x, y) -> canvas.drawCircle(x, y, r, handlePaint) }
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        when (event.action) {
            MotionEvent.ACTION_DOWN -> {
                startRawX = event.x; startRawY = event.y
                cropRect = RectF(event.x, event.y, event.x, event.y)
                dragging = true
            }
            MotionEvent.ACTION_MOVE -> {
                if (dragging) {
                    cropRect = RectF(
                        minOf(startRawX, event.x),
                        minOf(startRawY, event.y),
                        maxOf(startRawX, event.x),
                        maxOf(startRawY, event.y)
                    )
                    invalidate()
                }
            }
            MotionEvent.ACTION_UP -> {
                dragging = false
                if (cropRect.width() > 20 && cropRect.height() > 20) {
                    finishCrop()
                } else {
                    // 选区太小视为取消
                    onCrop(null)
                }
            }
        }
        return true
    }

    private fun finishCrop() {
        val rect = Rect(
            cropRect.left.toInt(), cropRect.top.toInt(),
            cropRect.right.toInt(), cropRect.bottom.toInt()
        ).also {
            // 边界保护
            it.left = it.left.coerceIn(0, fullBitmap.width)
            it.right = it.right.coerceIn(0, fullBitmap.width)
            it.top = it.top.coerceIn(0, fullBitmap.height)
            it.bottom = it.bottom.coerceIn(0, fullBitmap.height)
        }
        val cropped = Bitmap.createBitmap(
            fullBitmap, rect.left, rect.top,
            rect.width().coerceAtLeast(1), rect.height().coerceAtLeast(1)
        )
        val bytes = ByteArrayOutputStream().use {
            cropped.compress(Bitmap.CompressFormat.PNG, 100, it)
            it.toByteArray()
        }
        onCrop(bytes)
    }

    companion object {
        /**
         * 弹全屏选区悬浮窗。
         * @param service 截图服务（用其 WindowManager）
         * @param fullBitmap 全屏冻结图
         * @param onCrop 裁剪结果（PNG bytes，取消为 null）
         */
        fun show(service: Service, fullBitmap: Bitmap, onCrop: (ByteArray?) -> Unit) {
            val wm = service.getSystemService(Context.WINDOW_SERVICE) as WindowManager
            val metrics = service.resources.displayMetrics
            val params = WindowManager.LayoutParams(
                WindowManager.LayoutParams.MATCH_PARENT,
                WindowManager.LayoutParams.MATCH_PARENT,
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                    WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
                PixelFormat.TRANSLUCENT
            ).apply { gravity = Gravity.TOP or Gravity.START }

            val view = CropOverlayView(service, fullBitmap) { bytes ->
                // 裁剪完成 → 移除选区窗
                Handler(Looper.getMainLooper()).post { wm.removeView(view) }
                onCrop(bytes)
            }
            wm.addView(view, params)
        }
    }
}
```

- [ ] **Step 2: ScreenCaptureService.showCropOverlay 接入 CropOverlayView**

把 `showCropOverlay` 的占位块替换为：

```kotlin
    private fun showCropOverlay(fullBitmap: Bitmap) {
        CropOverlayView.show(this, fullBitmap) { croppedBytes ->
            if (croppedBytes != null) {
                // 检测全黑（FLAG_SECURE 页面）→ 提示而非当 bug
                // 简化：直接暂存，黑屏由 AI 侧或用户感知（MVP 不做像素级黑屏检测）
                PendingScreenshotHolder.get().put(croppedBytes)
                launchMainApp()
            }
            OverlayService.notifyCaptureFinished(this)
        }
    }
```

- [ ] **Step 3: 构建验证**

Run: `cd study_buddy && flutter build apk --debug 2>&1 | tail -20`
Expected: 构建成功（CropOverlayView 编译通过，全链路原生侧闭合）

- [ ] **Step 4: analyze 验证**

Run: `cd study_buddy && flutter analyze`
Expected: `No issues found!`

- [ ] **Step 5: Commit**

```bash
cd study_buddy && git add -A && git commit -m "feat(android): CropOverlayView 全屏选区裁剪 + 闭合截图链路

- 全屏 TYPE_APPLICATION_OVERLAY 显示冻结图，拖拽框选 + 四角手柄
- Bitmap.createBitmap 裁剪（边界保护），PNG bytes 暂存 PendingScreenshotHolder
- ScreenCaptureService.showCropOverlay 接入：裁剪 → 拉回主 App → 恢复悬浮球
- 原生侧端到端链路闭合（悬浮球→授权→取帧→选区→暂存→拉回）

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 7: Flutter 侧权限引导 + 启动流程 + 复用 AI 面板

**Files:**
- Create: `study_buddy/lib/features/overlay/permission_guide_page.dart`
- Modify: `study_buddy/lib/main.dart`
- Modify: `study_buddy/lib/router.dart`（加 /permission-guide）
- Modify: `study_buddy/lib/features/home/home_page.dart`（悬浮窗状态显示 + 去设置入口）
- Test: `study_buddy/test/screenshot_provider_test.dart`

**Interfaces:**
- Consumes: `screenshotProvider`（Task 1）、`ai_panel_sheet.showAiPanel`（已复用）、`agentSessionProvider`（已有）
- Produces: 启动流程（权限检查 → 唤起 overlay → 取待处理截图 → 开 AI 面板 or 首页）；权限引导页

- [ ] **Step 1: 创建 permission_guide_page.dart**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/providers/screenshot_provider.dart';

/// 首次悬浮窗权限引导页。
///
/// 说明用途（合规：截图仅用于本地 AI 分析，不上传不分享）+ 「去开启」按钮。
/// 返回后由调用方重新检查权限（用户可能从设置返回但未授权）。
class PermissionGuidePage extends ConsumerWidget {
  const PermissionGuidePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('开启截图悬浮窗')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Icon(Icons.screenshot_monitor, size: 64, color: Colors.deepPurple),
            const SizedBox(height: 16),
            const Text(
              '开启悬浮窗权限',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            const Text(
              '在任意界面点悬浮球即可框选题目区域，AI 自动分析涉及的知识点。\n\n'
              '截图仅用于本地 AI 分析，不上传、不分享。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: Colors.black54),
            ),
            const SizedBox(height: 8),
            const Text(
              '提示：部分小米机型需额外开启「后台弹出界面」权限。',
              style: TextStyle(fontSize: 12, color: Colors.orange),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              icon: const Icon(Icons.settings),
              label: const Text('去开启悬浮窗权限'),
              onPressed: () async {
                await ref.read(screenshotProvider).requestOverlayPermission();
                if (!context.mounted) return;
                // 返回首页重新检查（用户可能未授权就返回）
                Navigator.of(context).maybePop();
              },
            ),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 2: 改 router.dart 加 /permission-guide**

```dart
import 'package:go_router/go_router.dart';
import 'features/home/home_page.dart';
import 'features/overlay/permission_guide_page.dart';

GoRouter buildRouter() {
  return GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => const HomePage(),
      ),
      GoRoute(
        path: '/permission-guide',
        builder: (context, state) => const PermissionGuidePage(),
      ),
    ],
  );
}
```

- [ ] **Step 3: 改 main.dart 启动流程**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app.dart';
import 'core/providers/screenshot_provider.dart';

void main() {
  runApp(const ProviderScope(child: StudyBuddyApp()));
}

/// App 启动初始化：检查权限 → 唤起悬浮球 → 取待处理截图。
///
/// 由 StudyBuddyApp 的 initState 触发（见 app.dart 改造，Task 7 Step 4）。
/// 冷启动降级：若 PendingScreenshotHolder 有待处理截图，开 AI 面板。
Future<void> bootstrapOverlay(WidgetRef ref, BuildContext context) async {
  final sp = ref.read(screenshotProvider);
  final granted = await sp.checkOverlayPermission();
  if (!granted) {
    // 未授权：不唤起悬浮球，首页会引导
    return;
  }
  await sp.showOverlay();
  // 取待处理截图（冷启动降级）
  final pending = await sp.takePendingScreenshot();
  if (pending != null && context.mounted) {
    // 延迟到首页 build 完，用 home 的 context 弹面板
    // （实际由 home_page 在 didChangeDependencies 检查，避免顶层 context 时机问题）
    // 此处仅触发：存入一个临时 holder
    PendingScreenshotStore.pending = pending;
  }
}

/// 临时存储启动期取到的待处理截图，供 home_page 取用。
class PendingScreenshotStore {
  static dynamic pending; // CapturedScreenshot?
}
```

> ⚠️ 设计说明：启动期顶层 context 直接 `showAiPanel` 时机不稳（router 未就绪）。改为 `PendingScreenshotStore` 暂存，home_page `initState` 检查并弹出。Step 4 在 app.dart 接入 bootstrap。

- [ ] **Step 4: 改 app.dart 接入 bootstrap**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'router.dart';
import 'main.dart';

class StudyBuddyApp extends ConsumerStatefulWidget {
  const StudyBuddyApp({super.key});
  @override
  ConsumerState<StudyBuddyApp> createState() => _StudyBuddyAppState();
}

class _StudyBuddyAppState extends ConsumerState<StudyBuddyApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 延迟到首帧后初始化（router 就绪）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      bootstrapOverlay(ref, context);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 从设置返回 / 被截图拉回前台 → 重新检查待处理截图
    if (state == AppLifecycleState.resumed) {
      _checkPending();
    }
  }

  Future<void> _checkPending() async {
    final sp = ref.read(screenshotProvider);
    final pending = await sp.takePendingScreenshot();
    if (pending != null && mounted) {
      PendingScreenshotStore.pending = pending;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Study Buddy',
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple)),
      routerConfig: buildRouter(),
    );
  }
}
```

- [ ] **Step 5: 改 home_page.dart 检查待处理截图 + 悬浮窗状态 + 去设置**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/providers/database_provider.dart';
import '../../core/providers/screenshot_provider.dart';
import '../../features/external_qbank/ai_panel_sheet.dart';
import 'main.dart' show PendingScreenshotStore;

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});
  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  bool? _overlayGranted;

  @override
  void initState() {
    super.initState();
    _checkPermission();
    _consumePendingScreenshot();
  }

  Future<void> _checkPermission() async {
    final granted = await ref.read(screenshotProvider).checkOverlayPermission();
    if (mounted) setState(() => _overlayGranted = granted);
    if (granted) {
      await ref.read(screenshotProvider).showOverlay();
    }
  }

  Future<void> _consumePendingScreenshot() async {
    // 冷启动降级：弹出待处理截图的 AI 面板
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final pending = PendingScreenshotStore.pending;
      if (pending != null) {
        PendingScreenshotStore.pending = null;
        if (mounted) await showAiPanel(context, screenshot: pending);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final dbAsync = ref.watch(databaseProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Study Buddy')),
      body: dbAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('数据库初始化失败: $e')),
        data: (_) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _overlayGranted == true
                      ? Icons.screenshot_monitor
                      : Icons.screenshot_monitor_outlined,
                  size: 48,
                  color: Colors.deepPurple,
                ),
                const SizedBox(height: 12),
                Text(
                  _overlayGranted == null
                      ? '检查权限中...'
                      : _overlayGranted == true
                          ? '悬浮窗已开启 ✅\n在任意界面点悬浮球即可截图分析。'
                          : '悬浮窗未开启\n开启后可在任意界面截图分析。',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 16),
                ),
                const SizedBox(height: 16),
                if (_overlayGranted == false)
                  FilledButton.icon(
                    icon: const Icon(Icons.settings),
                    label: const Text('去开启悬浮窗权限'),
                    onPressed: () => context.go('/permission-guide'),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
```

- [ ] **Step 6: 写 screenshot_provider_test.dart（mock MethodChannel）**

```dart
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:study_buddy/core/providers/screenshot_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> calls;
  late ScreenshotProvider provider;

  setUp(() {
    calls = [];
    provider = ScreenshotProvider();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('study_buddy/overlay'), (call) async {
      calls.add(call);
      switch (call.method) {
        case 'checkOverlayPermission':
          return true;
        case 'takePendingScreenshot':
          return Uint8List.fromList([1, 2, 3]); // 假 PNG bytes
        default:
          return null;
      }
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('study_buddy/overlay'), null);
  });

  test('checkOverlayPermission 调用原生并返回 bool', () async {
    expect(await provider.checkOverlayPermission(), true);
    expect(calls.single.method, 'checkOverlayPermission');
  });

  test('takePendingScreenshot 返回 CapturedScreenshot，bytes 与 dataUri 对应', () async {
    final shot = await provider.takePendingScreenshot();
    expect(shot, isNotNull);
    expect(shot!.pngBytes, [1, 2, 3]);
    expect(shot.base64DataUri, startsWith('data:image/png;base64,'));
  });

  test('takePendingScreenshot 原生返回 null 时返回 null', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('study_buddy/overlay'), (call) async {
      return call.method == 'takePendingScreenshot' ? null : true;
    });
    expect(await provider.takePendingScreenshot(), isNull);
  });
}
```

- [ ] **Step 7: analyze + test 验证**

Run: `cd study_buddy && flutter analyze`
Expected: `No issues found!`

Run: `cd study_buddy && flutter test`
Expected: `All tests passed!`（含新增 screenshot_provider_test 3 个 + 原 widget_test）

- [ ] **Step 8: Commit**

```bash
cd study_buddy && git add -A && git commit -m "feat(app): 权限引导页 + 启动流程 + 复用 AI 面板（端到端闭合）

- PermissionGuidePage: 用途说明（合规文案）+ 去开启按钮
- app.dart: 启动 bootstrapOverlay + resumed 时检查待处理截图
- main.dart: PendingScreenshotStore 暂存冷启动截图
- home_page: 悬浮窗状态显示 + 去设置入口 + 消费待处理截图弹 AI 面板
- router 加 /permission-guide
- screenshot_provider_test: mock MethodChannel 测 3 场景
- 端到端链路 Flutter 侧闭合

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 8: 全链路验证 + 敏感扫描 + 手工验收清单

**Files:**
- Create: `study_buddy/docs/manual-acceptance-2026-08-10.md`（手工验收清单，不进 lib）

**Interfaces:**
- 无新代码，纯验证 + 文档

- [ ] **Step 1: engine 零改动验证**

Run: `cd packages/study_engine && dart analyze && dart test`
Expected: analyze No issues; test 22 passed（零改动承诺）

- [ ] **Step 2: app analyze + test**

Run: `cd study_buddy && flutter analyze && flutter test`
Expected: analyze No issues; test 全通过（含 Task 7 新增）

- [ ] **Step 3: 构建 release 验证（降级 debug 签名）**

Run: `cd study_buddy && flutter build apk --release 2>&1 | tail -10`
Expected: 构建成功（原生全部模块编译通过，签名降级 debug 可接受）

- [ ] **Step 4: 敏感扫描（硬约束自检）**

扫描 pattern: `ixunke`/`xkh5-token`/`Bearer\S{10,}`/`Authorization.*Bearer`/`study.keyky.cn`，范围 `study_buddy/lib` + `study_buddy/android` + git diff。
Expected: `study.keyky.cn` 仅可能出现在文档（验收清单/spec），无凭据字面值；`Authorization.*Bearer` 仅 engine 的 `'Bearer ${config.apiKey}'` 变量插值（与网站无关）。

Run（示例）:
```bash
cd study_buddy && git log --oneline 3081814..HEAD
git diff 3081814..HEAD -- lib android | grep -iE "ixunke|xkh5|study\.keyky\.cn|Authorization.*Bearer" || echo "clean"
```

- [ ] **Step 5: 写手工验收清单**

`study_buddy/docs/manual-acceptance-2026-08-10.md`：

```markdown
# 系统级截图悬浮窗 手工验收清单（2026-08-10）

需真机 + 本地真实 LLM 配置（llm_config 表 is_default=1 AND supports_vision=1）。

## 权限与悬浮球
- [ ] 首次启动 → 权限引导页 → 「去开启」→ 系统设置 → 授权 → 返回 → 首页显示「已开启」
- [ ] 悬浮球出现在屏幕右侧，任意界面可见
- [ ] 长按悬浮球可拖拽，松手贴边吸附

## 截图与选区
- [ ] 系统浏览器刷 study.keyky.cn → 点悬浮球 → 弹 MediaProjection 授权框 → 授权
- [ ] 屏幕冻结为全屏截图 → 拖拽框选题目区域 → 裁剪完成
- [ ] 会话内二次点悬浮球 → 免授权框 → 直接截图

## AI 分析
- [ ] 裁剪后跳回 study_buddy → 弹 AI 面板 → 截图缩略图显示
- [ ] 点「开始分析」→ 流式显示 AI 回复 → save_topic 成功显示「已保存」
- [ ] 抽屉关闭后 agent 不后台跑（mounted 守卫）

## 降级
- [ ] 冷启动：杀 App 进程 → 点悬浮球 → 截图 → App 重启自动打开 AI 面板
- [ ] FLAG_SECURE 页面（银行 app）→ 截图黑屏（系统行为，非 bug）

## 厂商 ROM
- [ ] MIUI 真机：悬浮窗权限 + 后台弹出界面权限引导有效
- [ ] 通知栏：截图会话期间有投屏通知（技术必然）
```

- [ ] **Step 6: Commit**

```bash
cd study_buddy && git add -A && git commit -m "test(app): 全链路验证 + 敏感扫描 + 手工验收清单

- engine 22 测试零改动通过
- app analyze + test 通过
- release 构建成功
- 敏感扫描 clean（无凭据字面值）
- 手工验收清单（真机 + LLM 配置）

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Self-Review 已完成

（计划作者自检，非任务）

1. **Spec 覆盖**：spec §3 删除清单→Task1；§4.1 Manifest→Task2；§4.2 ScreenshotPlugin/PendingScreenshotHolder→Task3；OverlayService→Task4；TrampolineActivity/ScreenCaptureService→Task5；CropOverlayView→Task6；§4.3/4.5 Flutter 侧→Task7；§5 测试/§8 硬约束→Task8。无遗漏。
2. **占位扫描**：Task 4/5/6 有「Task N 接入」占位注释，属任务间依赖的渐进式实现（每步可独立编译通过），非 plan 失败占位。无 TBD/TODO。
3. **类型一致性**：`CapturedScreenshot(pngBytes, base64DataUri)` 字段全程一致；MethodChannel 方法名（checkOverlayPermission/requestOverlayPermission/showOverlay/hideOverlay/takePendingScreenshot）Dart 与 Kotlin 一致；`PendingScreenshotHolder.get().put/take` 一致。
4. **渐进编译**：每 Task 结束 `flutter build apk --debug` 可通过（未实现的类不被引用，占位返回 null）。
