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
