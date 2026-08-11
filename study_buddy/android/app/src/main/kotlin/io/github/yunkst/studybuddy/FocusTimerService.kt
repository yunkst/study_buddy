package io.github.yunkst.studybuddy

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import androidx.core.app.NotificationCompat

/**
 * 专注计时前台服务。
 *
 * - startForeground 常驻通知（id=2001）
 * - 每秒刷新通知正文显示已专注时长
 * - 通知「停止」Action → 通过 MethodChannel 反向调用 Flutter 的 onStopped
 *
 * 计时主源在 Flutter，本服务只负责通知展示与转发停止意图。
 */
class FocusTimerService : Service() {
    companion object {
        const val CHANNEL_ID = "focus_timer"
        const val NOTIFICATION_ID = 2001
        const val ACTION_STOP = "io.github.yunkst.studybuddy.ACTION_FOCUS_STOP"
        private var startTimeMs: Long = 0L
        private val handler = Handler(Looper.getMainLooper())

        // 进程内运行标志：onStartCommand 置 true、onDestroy 置 false。
        // 替代 deprecated ActivityManager.getRunningServices——后者在国产 ROM
        // （华为/小米/OPPO）后台限制下对正在跑的前台服务误报 false，
        // 导致 recoverOrphan 把活跃会话当孤儿补结束（通知在跑但 app 不认）。
        @Volatile
        @JvmStatic
        private var running: Boolean = false

        fun isRunning(context: Context): Boolean = running
    }

    private val tickRunnable = object : Runnable {
        override fun run() {
            updateNotification()
            handler.postDelayed(this, 1000L)
        }
    }

    override fun onCreate() {
        super.onCreate()
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            // 立即停 tick：stopSelf → onDestroy 之间 tick 可能再跑一次刷新通知，
            // 造成「停止」后通知内容仍跳一下秒的视觉抖动。onDestroy 也会 remove，此处提前。
            handler.removeCallbacks(tickRunnable)
            // 先调 startForeground 再 stopSelf：服务存活时是 no-op 刷新；
            // 被系统回收后用户点残留通知重新拉起时，是正确的前台过渡（避免 ForegroundServiceStartNotAllowedException）。
            startForeground(NOTIFICATION_ID, buildNotification(elapsedMs = 0L))
            notifyFlutterStopped()
            stopSelf()
            return START_NOT_STICKY
        }
        startTimeMs = System.currentTimeMillis()
        startForeground(NOTIFICATION_ID, buildNotification(elapsedMs = 0L))
        handler.post(tickRunnable)
        running = true
        return START_NOT_STICKY
    }

    private fun updateNotification() {
        val elapsed = System.currentTimeMillis() - startTimeMs
        val mgr = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        mgr.notify(NOTIFICATION_ID, buildNotification(elapsed))
    }

    private fun buildNotification(elapsedMs: Long): Notification {
        val h = (elapsedMs / 3600000).toInt()
        val m = ((elapsedMs % 3600000) / 60000).toInt()
        val s = ((elapsedMs % 60000) / 1000).toInt()
        val text = "已专注 %02d:%02d:%02d".format(h, m, s)

        val stopIntent = Intent(this, FocusTimerService::class.java).apply {
            action = ACTION_STOP
        }
        val stopPi = PendingIntent.getService(
            this, 0, stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("正在专注学习")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_menu_recent_history)
            .setOngoing(true)
            .addAction(android.R.drawable.ic_media_pause, "停止", stopPi)
            .build()
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val mgr = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (mgr.getNotificationChannel(CHANNEL_ID) == null) {
                val ch = NotificationChannel(
                    CHANNEL_ID, "专注计时", NotificationManager.IMPORTANCE_LOW
                ).apply { description = "专注学习计时通知" }
                mgr.createNotificationChannel(ch)
            }
        }
    }

    private fun notifyFlutterStopped() {
        val m = FocusTimerPlugin.messenger ?: return
        io.flutter.plugin.common.MethodChannel(m, "study_buddy/focus")
            .invokeMethod("onStopped", null)
    }

    override fun onDestroy() {
        handler.removeCallbacks(tickRunnable)
        running = false
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
