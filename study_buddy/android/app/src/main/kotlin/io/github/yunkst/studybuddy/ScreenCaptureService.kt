package io.github.yunkst.studybuddy

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.app.Activity
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
        projection = mpm.getMediaProjection(Activity.RESULT_OK, authIntent)
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
