package com.example.volysample.widget

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.util.AttributeSet
import android.util.TypedValue
import android.view.View
import androidx.core.content.withStyledAttributes
import com.example.volysample.R
import kotlin.math.max

/**
 * A pill with a short label. An app-defined view class with two custom
 * properties ([badgeText], [badgeColor]) for the inspector to find.
 */
class BadgeView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = 0,
) : View(context, attrs, defStyleAttr) {

    var badgeText: String = ""
        set(value) {
            if (field == value) return
            field = value
            requestLayout()
            invalidate()
        }

    var badgeColor: Int = Color.DKGRAY
        set(value) {
            if (field == value) return
            field = value
            invalidate()
        }

    private val density = resources.displayMetrics.density
    private val minSize = (28 * density).toInt()
    private val horizontalPadding = 10 * density

    private val fillPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val textPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        textAlign = Paint.Align.CENTER
        textSize = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, 14f, resources.displayMetrics)
        isFakeBoldText = true
    }

    init {
        context.withStyledAttributes(attrs, R.styleable.BadgeView, defStyleAttr) {
            badgeText = getString(R.styleable.BadgeView_badgeText).orEmpty()
            badgeColor = getColor(R.styleable.BadgeView_badgeColor, badgeColor)
        }
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val textWidth = (textPaint.measureText(badgeText) + 2 * horizontalPadding).toInt()
        setMeasuredDimension(
            resolveSize(max(minSize, textWidth), widthMeasureSpec),
            resolveSize(minSize, heightMeasureSpec),
        )
    }

    override fun onDraw(canvas: Canvas) {
        fillPaint.color = badgeColor
        val radius = height / 2f
        canvas.drawRoundRect(0f, 0f, width.toFloat(), height.toFloat(), radius, radius, fillPaint)
        val baseline = height / 2f - (textPaint.descent() + textPaint.ascent()) / 2f
        canvas.drawText(badgeText, width / 2f, baseline, textPaint)
    }
}
