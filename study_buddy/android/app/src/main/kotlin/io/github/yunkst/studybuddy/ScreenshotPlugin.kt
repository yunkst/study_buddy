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
