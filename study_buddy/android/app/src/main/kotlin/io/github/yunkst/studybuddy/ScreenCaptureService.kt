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
    /** 取首帧守卫：避免 VirtualDisplay 持续镜像导致 listener 重复收帧 → 重复 showCropOverlay。 */
    private val frameCaptured = java.util.concurrent.atomic.AtomicBoolean(false)

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
        } else if (alive) {
            // 会话内存活：无授权 Intent，复用 projection 取新帧
            captureAgain()
        }
        return START_STICKY
    }

    private fun setupSession(authIntent: Intent) {
        // 闭合 C：释放旧会话，避免重复 setupSession 泄漏 + 多 listener（MVP 会话制每次重新授权）
        virtualDisplay?.release(); virtualDisplay = null
        imageReader?.close(); imageReader = null
        projection?.stop(); projection = null

        val mpm = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        // Android 14+：必须先 startForeground（onCreate 已做）再 getMediaProjection
        projection = mpm.getMediaProjection(Activity.RESULT_OK, authIntent)
        if (projection == null) {
            // 闭合 D：getMediaProjection 失败 → 释放已建资源（此时 imageReader 尚未建，仅作保险）
            imageReader?.close(); imageReader = null
            return
        }
        projection?.registerCallback(object : MediaProjection.Callback() {
            override fun onStop() {
                projection = null
                virtualDisplay?.release(); virtualDisplay = null
                // 闭合 D：projection 停止时关闭 imageReader（onDestroy 已有，此处覆盖运行期 stop）
                imageReader?.close(); imageReader = null
                alive = false
            }
        }, Handler(Looper.getMainLooper()))

        imageReader = ImageReader.newInstance(width, height, PixelFormat.RGBA_8888, 2)
        virtualDisplay = projection?.createVirtualDisplay(
            "study_capture", width, height, density,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            imageReader!!.surface, null, null
        )
        // 闭合 B：AtomicBoolean 守卫，取首帧后移除 listener，避免重复 showCropOverlay
        frameCaptured.set(false)
        armFrameListener()
        // 会话建立成功 → 标记存活，后续截图走 requestCapture 免授权复用
        alive = true
    }

    /**
     * 挂 ImageReader 取帧 listener：取到首帧后 detach（避免重复 showCropOverlay）。
     * 会话制下 requestCapture() 会重新调用本方法取新帧。
     */
    private fun armFrameListener() {
        val reader = imageReader ?: return
        reader.setOnImageAvailableListener({ r ->
            if (!frameCaptured.compareAndSet(false, true)) return@setOnImageAvailableListener
            val image = r.acquireLatestImage() ?: return@setOnImageAvailableListener
            val bmp = image.toBitmap()
            image.close()
            r.setOnImageAvailableListener(null, null)  // 停止收帧
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

    /** 弹全屏选区悬浮窗，裁剪后暂存并拉回主 App。 */
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

    private fun launchMainApp() {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        launchIntent?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        startActivity(launchIntent)
    }

    /** 会话内再次截图：VirtualDisplay 已在，重置守卫 + 重挂 listener 取新帧。 */
    private fun captureAgain() {
        frameCaptured.set(false)
        armFrameListener()
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
        alive = false
    }

    companion object {
        private const val NOTIFICATION_ID = 1002
        @Volatile private var alive = false
        fun isSessionAlive(): Boolean = alive

        /**
         * 会话内存活时由 TrampolineActivity 调用：重新拉起本服务（不带 EXTRA），
         * onStartCommand 检测到 alive=true → captureAgain() 取新帧，免重新授权。
         */
        fun requestCapture(ctx: Context) {
            val intent = Intent(ctx, ScreenCaptureService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                ctx.startForegroundService(intent)
            } else {
                ctx.startService(intent)
            }
        }
    }
}
