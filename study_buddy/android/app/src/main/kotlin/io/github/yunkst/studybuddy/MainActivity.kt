package io.github.yunkst.studybuddy

import android.content.Intent
import android.net.Uri
import android.os.Build
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File

class MainActivity : FlutterActivity() {
    private val APP_INSTALL_CHANNEL = "io.github.yunkst.studybuddy/app_install"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(FocusTimerPlugin())

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, APP_INSTALL_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "installApk") {
                    val filePath = call.argument<String>("filePath")
                    if (filePath != null) {
                        if (installApk(filePath)) {
                            result.success(true)
                        } else {
                            result.error("INSTALL_FAILED", "Failed to install APK", null)
                        }
                    } else {
                        result.error("INVALID_ARGUMENT", "File path is required", null)
                    }
                } else {
                    result.notImplemented()
                }
            }

        // 系统分享接收（图片）：外部 App 通过 ACTION_SEND 分享图片给 Study Buddy。
        // - 热启动：App 已在前台，分享唤起走 onNewIntent → 读 bytes → shareSink 推给 Flutter。
        // - 冷启动：App 被杀后从分享打开，onCreate/onNewIntent 读 intent → 暂存静态 holder，
        //   Flutter 侧 EventChannel onListen 时 flush 给 Dart（纯原生实现，无插件依赖）。
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, SHARE_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    shareSink = events
                    flushPendingShare()
                }

                override fun onCancel(arguments: Any?) {
                    shareSink = null
                }
            })

        // 冷启动：Flutter engine 就绪后，消费 onCreate 传入的分享 intent（如果有）。
        flushPendingShare()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // 热启动：App 已在前台（singleTop），系统分享派发到 onNewIntent。
        setIntent(intent) // 后续 getIntent() 读最新
        handleShareIntent(intent)
    }

    override fun onStart() {
        super.onStart()
        // 冷启动：onCreate 的 ACTION_SEND intent 在 configureFlutterEngine 之后才可安全读取
        //（engine 就绪前读 content Uri 可能因权限/生命周期时序失败）。
        // 此处兜底调用一次：Flutter 未订阅（sink 空）→ 存 pendingShareBytes，onListen 时 flush。
        handleShareIntent(intent)
    }

    /// 解析 ACTION_SEND / SEND_MULTIPLE 的图片 Uri → bytes → 推给 Flutter。
    private fun handleShareIntent(intent: Intent?) {
        if (intent == null) return
        val action = intent.action ?: return
        if (action != Intent.ACTION_SEND && action != Intent.ACTION_SEND_MULTIPLE) return
        val type = intent.type ?: return
        if (!type.startsWith("image/")) return

        val bytes = if (action == Intent.ACTION_SEND) {
            val uri = intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM) ?: return
            readUriBytes(uri) ?: return
        } else {
            // SEND_MULTIPLE：只取第一张图进 AI 面板（与悬浮球回流行为一致）。
            val uris = intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
            if (uris.isNullOrEmpty()) return
            val firstImage = uris.firstOrNull { isImageUri(it) } ?: return
            readUriBytes(firstImage) ?: return
        }
        if (bytes.isEmpty()) return

        val sink = shareSink
        if (sink != null) {
            // 热路径：Flutter 已订阅 EventChannel，直接推送。
            sink.success(bytes)
        } else {
            // 冷路径：Flutter 未就绪，暂存静态 holder，onListen 时 flush。
            pendingShareBytes = bytes
        }
    }

    private fun isImageUri(uri: Uri): Boolean {
        val type = contentResolver.getType(uri) ?: return false
        return type.startsWith("image/")
    }

    /// 从 content Uri 读 bytes（需 FLAG_GRANT_READ_URI_PERMISSION；系统分享 intent 自带）。
    private fun readUriBytes(uri: Uri): ByteArray? {
        return try {
            contentResolver.openInputStream(uri)?.use { input ->
                ByteArrayOutputStream().use { out ->
                    val buf = ByteArray(64 * 1024)
                    while (true) {
                        val n = input.read(buf)
                        if (n < 0) break
                        out.write(buf, 0, n)
                    }
                    out.toByteArray()
                }
            }
        } catch (e: Exception) {
            e.printStackTrace()
            null
        }
    }

    /// 冷路径 flush：Flutter EventChannel 就绪后把暂存字节推过去并清空。
    private fun flushPendingShare() {
        val bytes = pendingShareBytes ?: return
        val sink = shareSink ?: return
        pendingShareBytes = null
        sink.success(bytes)
    }

    /// 用 FileProvider + Intent 触发系统 APK 安装器
    private fun installApk(filePath: String): Boolean {
        return try {
            val file = File(filePath)
            if (!file.exists()) return false

            val intent = Intent(Intent.ACTION_VIEW).apply {
                val uri = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    FileProvider.getUriForFile(
                        this@MainActivity,
                        "$packageName.fileprovider",
                        file
                    )
                } else {
                    Uri.fromFile(file)
                }
                setDataAndType(uri, "application/vnd.android.package-archive")
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION
            }
            startActivity(intent)
            true
        } catch (e: Exception) {
            e.printStackTrace()
            false
        }
    }

    companion object {
        const val SHARE_CHANNEL = "study_buddy/share"

        /// 冷启动暂存：Flutter 未就绪时收到的分享 bytes，onListen 后 flush。
        @Volatile
        private var pendingShareBytes: ByteArray? = null

        /// 热启动 EventSink：Flutter 侧 onListen 时赋值，onCancel 置空。
        @Volatile
        private var shareSink: EventChannel.EventSink? = null
    }
}
