package io.github.ccch1mneyyy.dsh_app.phone.a11y

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Typeface
import android.graphics.drawable.Drawable
import android.graphics.drawable.GradientDrawable
import android.view.Gravity
import android.view.View
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView

/**
 * Which image the preview may show. Revision events and snapshots have no shared order
 * (PhonePreview): a newer event drops the image before the read, an older answer never restores it.
 */
internal class PreviewTracker {
    private var newest = -1L

    var image: ByteArray? = null
        private set
    var capturedAt: Long? = null
        private set

    /** True when the snapshot should be read now. */
    fun event(revision: Long): Boolean {
        if (revision <= newest) return false
        newest = revision
        image = null
        capturedAt = null
        return true
    }

    fun snapshot(revision: Long, jpeg: ByteArray?, at: Long?) {
        if (revision < newest) return
        newest = revision
        image = jpeg
        capturedAt = at
    }
}

/**
 * The read-only preview (#287): the last image a screen tool returned in this task, in its own
 * window. A result snapshot, not a live view, and nothing here reaches the screen it shows.
 * Main thread only; the owner ([ControlOverlay]) adds and removes the window.
 */
internal class OverlayPreview(
    private val ctx: Context,
    c: OverlayPalette,
    card: Drawable,
    strings: Strings,
    onClose: () -> Unit,
) {
    class Strings(val title: String, val close: String, val image: String, val empty: String)

    private val age = TextView(ctx).apply {
        textSize = 11f
        setTextColor(c.faint)
        setPadding(ctx.dp(8), 0, 0, 0)
    }

    private val image = ImageView(ctx).apply {
        adjustViewBounds = true
        scaleType = ImageView.ScaleType.FIT_CENTER
        contentDescription = strings.image
        background = GradientDrawable().apply { cornerRadius = ctx.dpf(14f); setColor(c.field) }
        clipToOutline = true
    }

    private val empty = TextView(ctx).apply {
        text = strings.empty
        textSize = 13f
        setTextColor(c.muted)
        gravity = Gravity.CENTER
        setPadding(ctx.dp(16), ctx.dp(28), ctx.dp(16), ctx.dp(32))
    }

    val root = FrameLayout(ctx).apply {
        setPadding(ctx.dp(6), ctx.dp(8), ctx.dp(6), ctx.dp(6))
        clipToPadding = false
        addView(LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            background = card
            elevation = ctx.dpf(8f)
            isClickable = true
            setPadding(ctx.dp(PAD_DP), ctx.dp(4), ctx.dp(4), ctx.dp(PAD_DP))
            addView(LinearLayout(ctx).apply {
                gravity = Gravity.CENTER_VERTICAL
                addView(TextView(ctx).apply {
                    text = strings.title
                    textSize = 13f
                    setTextColor(c.ink)
                    typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
                })
                addView(age, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
                addView(RoundKey(ctx, 32, 18).apply {
                    setGlyph(Glyph.CLOSE, false)
                    ink = c.muted
                    contentDescription = strings.close
                    setOnClickListener { onClose() }
                }, LinearLayout.LayoutParams(ctx.dp(44), ctx.dp(44)))
            })
            addView(image, LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT,
            ).apply { marginEnd = ctx.dp(PAD_DP - 4) })
            addView(empty, LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT,
            ).apply { marginEnd = ctx.dp(PAD_DP - 4) })
        }, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.WRAP_CONTENT))
    }

    fun show(bitmap: Bitmap?, ageText: String?) {
        image.setImageBitmap(bitmap)
        image.visibility = if (bitmap == null) View.GONE else View.VISIBLE
        empty.visibility = if (bitmap == null) View.VISIBLE else View.GONE
        age.text = ageText.orEmpty()
    }

    fun setAge(text: String?) {
        age.text = text.orEmpty()
    }

    /** The window's width: it hugs the picture, so a tall screen gets a narrow card, not bands beside it. */
    fun widthFor(bitmap: Bitmap?, screenW: Int, screenH: Int): Int {
        val most = screenW - ctx.dp(12)
        val imageH = (screenH * MAX_IMAGE_SHARE).toInt()
        image.maxHeight = imageH
        if (bitmap == null || bitmap.height == 0) return minOf(most, ctx.dp(280))
        val chrome = ctx.dp(2 * PAD_DP + 12)
        return (imageH.toLong() * bitmap.width / bitmap.height + chrome).toInt().coerceIn(minOf(most, ctx.dp(220)), most)
    }

    private companion object {
        const val PAD_DP = 12
        const val MAX_IMAGE_SHARE = 0.5f
    }
}
