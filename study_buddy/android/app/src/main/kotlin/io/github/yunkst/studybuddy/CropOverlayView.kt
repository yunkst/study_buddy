package io.github.yunkst.studybuddy

import android.app.Service
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.Rect
import android.graphics.RectF
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import java.io.ByteArrayOutputStream

/**
 * 全屏选区悬浮窗：显示冻结全屏截图 + 拖拽框选 + 四角手柄 + 裁剪。
 *
 * 形态：第二个 TYPE_APPLICATION_OVERLAY（可触摸），非 Activity——瞬时出现无闪屏。
 * 裁剪：Bitmap.createBitmap(full, x, y, w, h)；VirtualDisplay 物理像素 vs 触摸坐标
 * 需 density 换算（本 view 全屏，触摸坐标 = 物理像素，无需额外换算）。
 */
class CropOverlayView private constructor(
    context: Context,
    private val fullBitmap: Bitmap,
    private val onCrop: (ByteArray?) -> Unit
) : View(context) {

    private val bgPaint = Paint().apply { color = Color.parseColor("#CC000000") }
    private val borderPaint = Paint().apply {
        color = Color.WHITE; style = Paint.Style.STROKE; strokeWidth = 4f; isAntiAlias = true
    }
    private val handlePaint = Paint().apply { color = Color.WHITE; isAntiAlias = true }
    private var startRawX = 0f
    private var startRawY = 0f
    private var cropRect = RectF()
    private var dragging = false

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        // 冻结全屏图作背景
        canvas.drawBitmap(fullBitmap, 0f, 0f, null)
        // 选区外半透明遮罩
        canvas.drawRect(0f, 0f, width.toFloat(), cropRect.top, bgPaint)
        canvas.drawRect(0f, cropRect.bottom, width.toFloat(), height.toFloat(), bgPaint)
        canvas.drawRect(0f, cropRect.top, cropRect.left, cropRect.bottom, bgPaint)
        canvas.drawRect(cropRect.right, cropRect.top, width.toFloat(), cropRect.bottom, bgPaint)
        // 选区边框
        if (!cropRect.isEmpty) {
            canvas.drawRect(cropRect, borderPaint)
            drawHandles(canvas)
        }
    }

    private fun drawHandles(canvas: Canvas) {
        val r = 16f
        val corners = listOf(
            cropRect.left to cropRect.top,
            cropRect.right to cropRect.top,
            cropRect.left to cropRect.bottom,
            cropRect.right to cropRect.bottom
        )
        corners.forEach { (x, y) -> canvas.drawCircle(x, y, r, handlePaint) }
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        when (event.action) {
            MotionEvent.ACTION_DOWN -> {
                startRawX = event.x; startRawY = event.y
                cropRect = RectF(event.x, event.y, event.x, event.y)
                dragging = true
            }
            MotionEvent.ACTION_MOVE -> {
                if (dragging) {
                    cropRect = RectF(
                        minOf(startRawX, event.x),
                        minOf(startRawY, event.y),
                        maxOf(startRawX, event.x),
                        maxOf(startRawY, event.y)
                    )
                    invalidate()
                }
            }
            MotionEvent.ACTION_UP -> {
                dragging = false
                if (cropRect.width() > 20 && cropRect.height() > 20) {
                    finishCrop()
                } else {
                    // 选区太小视为取消
                    onCrop(null)
                }
            }
        }
        return true
    }

    private fun finishCrop() {
        val rect = Rect(
            cropRect.left.toInt(), cropRect.top.toInt(),
            cropRect.right.toInt(), cropRect.bottom.toInt()
        ).also {
            // 边界保护
            it.left = it.left.coerceIn(0, fullBitmap.width)
            it.right = it.right.coerceIn(0, fullBitmap.width)
            it.top = it.top.coerceIn(0, fullBitmap.height)
            it.bottom = it.bottom.coerceIn(0, fullBitmap.height)
        }
        val cropped = Bitmap.createBitmap(
            fullBitmap, rect.left, rect.top,
            rect.width().coerceAtLeast(1), rect.height().coerceAtLeast(1)
        )
        val bytes = ByteArrayOutputStream().use {
            cropped.compress(Bitmap.CompressFormat.PNG, 100, it)
            it.toByteArray()
        }
        onCrop(bytes)
    }

    companion object {
        /**
         * 弹全屏选区悬浮窗。
         * @param service 截图服务（用其 WindowManager）
         * @param fullBitmap 全屏冻结图
         * @param onCrop 裁剪结果（PNG bytes，取消为 null）
         */
        fun show(service: Service, fullBitmap: Bitmap, onCrop: (ByteArray?) -> Unit) {
            val wm = service.getSystemService(Context.WINDOW_SERVICE) as WindowManager
            val params = WindowManager.LayoutParams(
                WindowManager.LayoutParams.MATCH_PARENT,
                WindowManager.LayoutParams.MATCH_PARENT,
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                    WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
                PixelFormat.TRANSLUCENT
            ).apply { gravity = Gravity.TOP or Gravity.START }

            // 自引用：lambda 内移除自己 → 用 var 先占位（运行期回调触发时已 addView，引用非空）
            var view: CropOverlayView? = null
            view = CropOverlayView(service, fullBitmap) { bytes ->
                Handler(Looper.getMainLooper()).post { wm.removeView(view) }
                onCrop(bytes)
            }
            wm.addView(view!!, params)
        }
    }
}
