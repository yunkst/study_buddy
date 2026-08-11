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
        // 会话已存在（ScreenCaptureService 存活）→ 直接复用 projection 取新帧，不弹授权
        if (ScreenCaptureService.isSessionAlive()) {
            ScreenCaptureService.requestCapture(this)
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
