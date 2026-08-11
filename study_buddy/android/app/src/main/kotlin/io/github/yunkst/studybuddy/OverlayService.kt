package io.github.yunkst.studybuddy

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
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

    /**
     * App 前台抑制标志：true 时不恢复悬浮球（即使截图回流 notifyCaptureFinished）。
     * 由 onStartCommand 按 action 维护：
     * - ACTION_HIDE_OVERLAY → true（来自 Flutter 切到前台）
     * - ACTION_SHOW_OVERLAY → false（来自 Flutter 切到后台 / 外部恢复）
     * - 截图回流（action 为 null）→ 仅在 false 时恢复，避免与前台隐藏竞态
     */
    @Volatile
    private var suppressedByForeground = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        windowManager = getSystemService(WINDOW_SERVICE) as WindowManager
        startForeground(NOTIFICATION_ID, buildNotification())
        if (Settings.canDrawOverlays(this)) {
            showFloatBall()
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForeground(NOTIFICATION_ID, buildNotification())
        when (intent?.action) {
            ACTION_HIDE_OVERLAY -> {
                // 轻量隐藏：只移除 floatView，保留 FGS 通知，绝不 stopService。
                suppressedByForeground = true
                hideOverlay()
            }
            ACTION_SHOW_OVERLAY -> {
                // 恢复：清除前台抑制（用户进后台 / 外部唤起）。
                suppressedByForeground = false
                showOverlayInternal()
            }
            else -> {
                // 默认（首次启动 / notifyCaptureFinished 截图回流）。
                // 截图回流时若 App 在前台（suppressedByForeground=true），不恢复悬浮球，避免竞态。
                if (!suppressedByForeground && floatView == null && Settings.canDrawOverlays(this)) {
                    showFloatBall()
                }
            }
        }
        return START_STICKY
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
     * 点击悬浮球 → 轻量 hide（置 suppressedByForeground=true，覆盖 paused→showOverlay 复位漏洞）
     * → 启动 TrampolineActivity 走 MediaProjection 授权 + 截图。
     */
    private fun triggerScreenshot() {
        val intent = Intent(this, OverlayService::class.java)
            .setAction(OverlayService.ACTION_HIDE_OVERLAY)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
        startActivity(Intent(this, TrampolineActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
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

        /**
         * onStartCommand 通过 intent action 区分操作：
         * - HIDE_OVERLAY：轻量 hide（保留 FGS），同时置 suppressedByForeground=true
         * - SHOW_OVERLAY：恢复悬浮球，同时复位 suppressedByForeground=false
         * - null（默认启动 / notifyCaptureFinished 截图回流）：仅在未抑制时恢复
         */
        const val ACTION_HIDE_OVERLAY = "io.github.yunkst.studybuddy.action.HIDE_OVERLAY"
        const val ACTION_SHOW_OVERLAY = "io.github.yunkst.studybuddy.action.SHOW_OVERLAY"

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
}
