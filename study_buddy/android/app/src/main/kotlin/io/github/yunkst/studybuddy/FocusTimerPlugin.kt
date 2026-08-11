package io.github.yunkst.studybuddy

import android.content.Intent
import android.os.Build
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 专注计时 MethodChannel("study_buddy/focus") 桥接。
 *
 * - start(sessionId) → 启动 FocusTimerService 前台服务
 * - stop → 停止服务
 * - isRunning → 查服务是否在跑
 * - onStopped（反向）→ service 通过本 plugin 缓存的 messenger 调 Flutter
 */
class FocusTimerPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    companion object {
        var messenger: io.flutter.plugin.common.BinaryMessenger? = null
    }

    private var channel: MethodChannel? = null
    private var appContext: android.content.Context? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        messenger = binding.binaryMessenger
        channel = MethodChannel(binding.binaryMessenger, "study_buddy/focus").also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        messenger = null
        appContext = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> {
                val ctx = appContext ?: run { result.success(null); return }
                val intent = Intent(ctx, FocusTimerService::class.java)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    ctx.startForegroundService(intent)
                } else {
                    ctx.startService(intent)
                }
                result.success(null)
            }
            "stop" -> {
                appContext?.let {
                    it.stopService(Intent(it, FocusTimerService::class.java))
                }
                result.success(null)
            }
            "isRunning" -> {
                val running = appContext?.let { FocusTimerService.isRunning(it) } ?: false
                result.success(running)
            }
            else -> result.notImplemented()
        }
    }
}
