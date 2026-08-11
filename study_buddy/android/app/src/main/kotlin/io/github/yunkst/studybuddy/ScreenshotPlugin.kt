package io.github.yunkst.studybuddy

import android.content.Context
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
 * - showOverlay / hideOverlay: 通过 intent action 驱动 OverlayService（轻量 hide，保留 FGS 通知）
 * - takePendingScreenshot: 从 PendingScreenshotHolder 取
 *
 * hideOverlay 走 ACTION_HIDE_OVERLAY 而非 stopService，避免销毁前台服务；
 * 配合 OverlayService.suppressedByForeground 标志解决截图回流与前台隐藏竞态。
 */
class ScreenshotPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private var appContext: Context? = null

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
                val ctx = appContext ?: run { result.success(null); return }
                // 走 ACTION_SHOW_OVERLAY：恢复悬浮球 + 复位 suppressedByForeground。
                // 冷启动时 service 未运行，startForegroundService 先 onCreate（showFloatBall）
                // 再 onStartCommand（ACTION_SHOW_OVERLAY → showOverlayInternal，floatView 非 null 跳过，无害）。
                val intent = Intent(ctx, OverlayService::class.java)
                    .setAction(OverlayService.ACTION_SHOW_OVERLAY)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    ctx.startForegroundService(intent)
                } else {
                    ctx.startService(intent)
                }
                result.success(null)
            }
            "hideOverlay" -> {
                val ctx = appContext ?: run { result.success(null); return }
                // 轻量 hide：只移除 floatView，保留 FGS 通知，绝不 stopService。
                val intent = Intent(ctx, OverlayService::class.java)
                    .setAction(OverlayService.ACTION_HIDE_OVERLAY)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    ctx.startForegroundService(intent)
                } else {
                    ctx.startService(intent)
                }
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
