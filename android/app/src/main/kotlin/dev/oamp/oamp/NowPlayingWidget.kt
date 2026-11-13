package dev.oamp.oamp

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.res.Resources
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.util.SizeF
import android.util.TypedValue
import android.view.View
import android.widget.RemoteViews
import java.io.File
import java.util.concurrent.Executors

/**
 * OAmp's home screen widget: the cover, title and artist of what is
 * playing, with previous, play/pause and next. Tapping anywhere else opens
 * the app.
 *
 * The app tells the widget what to draw (AndroidHomeWidget in Dart, through
 * MainActivity's `oamp/widget` channel) whenever the track or play state
 * changes; there are no timed updates. The buttons go straight to the
 * media session, the same way the notification's do, so the player hears
 * them as ordinary media buttons.
 *
 * What is showing is kept only in memory. When the app isn't running there
 * is no session to send buttons to, so the widget shows "Tap to open".
 */
class NowPlayingWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        redraw(context, ids)
    }

    /** Resized: laid out again for the new size. */
    override fun onAppWidgetOptionsChanged(
        context: Context,
        manager: AppWidgetManager,
        id: Int,
        options: Bundle,
    ) {
        redraw(context, intArrayOf(id))
    }

    /** What the widget shows while something is loaded. */
    data class State(
        val title: String,
        val artist: String?,
        val artPath: String?,
        val playing: Boolean,
        val canGoNext: Boolean,
        val canGoPrevious: Boolean,
    )

    companion object {
        const val ACTION_PLAY_PAUSE = "dev.oamp.oamp.widget.PLAY_PAUSE"
        const val ACTION_NEXT = "dev.oamp.oamp.widget.NEXT"
        const val ACTION_PREVIOUS = "dev.oamp.oamp.widget.PREVIOUS"

        /** Large enough for the square widget on a big phone, small enough to stay cheap. */
        private const val ART_SIZE = 384

        /** Below this height (dp) the widget is a single row. */
        private const val ROW_MAX_HEIGHT = 110f

        /** At least this much wider than high, a tall widget keeps the cover beside the text. */
        private const val WIDE_RATIO = 1.6f

        /** The least room (dp) the title gets in the single-row widget. */
        private const val ROW_TEXT_MIN = 72f

        /** RemoteViews takes at most this many sizes. */
        private const val MAX_SIZES = 16

        /** Before the launcher has said: 4x1, 4x2 and 3x3, roughly. */
        private val DEFAULT_SIZES = listOf(SizeF(250f, 60f), SizeF(250f, 150f), SizeF(200f, 200f))

        /** What is showing, or null for "Tap to open". */
        @Volatile
        var state: State? = null
            private set

        /** Covers are decoded and widgets redrawn off the main thread, in order. */
        private val worker = Executors.newSingleThreadExecutor()

        /** The last cover decoded, so a play/pause press doesn't decode it again. */
        private var artCache: Pair<String, Bitmap?>? = null

        fun show(context: Context, next: State) {
            state = next
            redraw(context.applicationContext, null)
        }

        fun clear(context: Context) {
            state = null
            redraw(context.applicationContext, null)
        }

        private fun redraw(context: Context, ids: IntArray?) {
            val app = context.applicationContext
            worker.execute {
                try {
                    val manager = AppWidgetManager.getInstance(app)
                    val all = ids ?: manager.getAppWidgetIds(
                        ComponentName(app, NowPlayingWidget::class.java),
                    )
                    if (all.isEmpty()) return@execute
                    val shown = state
                    val art = shown?.artPath?.let { cover(app, it) }
                    for (id in all) {
                        manager.updateAppWidget(id, viewsFor(app, manager, id, shown, art))
                    }
                } catch (e: RuntimeException) {
                    Log.w("OAmp", "Home screen widget not updated", e)
                }
            }
        }

        /**
         * Views for each size the widget can be shown at. Android 12+ says
         * which sizes those are (portrait and landscape), and draws the
         * matching one; older versions get one layout for the size given.
         */
        private fun viewsFor(
            context: Context,
            manager: AppWidgetManager,
            id: Int,
            shown: State?,
            art: Bitmap?,
        ): RemoteViews {
            val options = manager.getAppWidgetOptions(id)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                @Suppress("DEPRECATION")
                val sizes = options.getParcelableArrayList<SizeF>(
                    AppWidgetManager.OPTION_APPWIDGET_SIZES,
                )?.distinct()?.take(MAX_SIZES)
                val all = if (sizes.isNullOrEmpty()) DEFAULT_SIZES else sizes
                return RemoteViews(all.associateWith { build(context, it, shown, art, scale = true) })
            }
            // Older launchers give a range; portrait is narrowest and tallest.
            val width = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH)
            val height = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT)
            val size = if (width > 0 && height > 0) {
                SizeF(width.toFloat(), height.toFloat())
            } else {
                DEFAULT_SIZES.first()
            }
            return build(context, size, shown, art, scale = false)
        }

        /** Which layout suits a widget of [size] (in dp). */
        internal fun layoutFor(size: SizeF): Int = when {
            size.height < ROW_MAX_HEIGHT -> R.layout.widget_now_playing
            size.width >= size.height * WIDE_RATIO -> R.layout.widget_now_playing_large
            else -> R.layout.widget_now_playing_square
        }

        private fun build(
            context: Context,
            size: SizeF,
            shown: State?,
            art: Bitmap?,
            scale: Boolean,
        ): RemoteViews {
            val layout = layoutFor(size)
            val views = RemoteViews(context.packageName, layout)
            // Setting view sizes from code needs Android 12; older versions
            // keep each layout's own sizes.
            if (scale && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                fit(views, layout, size)
            }
            views.setOnClickPendingIntent(R.id.widget_root, openApp(context))
            if (art != null) {
                views.setImageViewBitmap(R.id.widget_art, art)
            } else {
                views.setImageViewResource(R.id.widget_art, R.drawable.ic_widget_no_art)
            }
            if (shown == null) {
                views.setTextViewText(R.id.widget_title, context.getString(R.string.widget_idle_title))
                views.setTextViewText(
                    R.id.widget_artist,
                    context.getString(R.string.widget_idle_subtitle),
                )
                views.setViewVisibility(R.id.widget_artist, View.VISIBLE)
                for (id in listOf(R.id.widget_previous, R.id.widget_play_pause, R.id.widget_next)) {
                    views.setViewVisibility(id, View.GONE)
                }
                views.setContentDescription(R.id.widget_root, context.getString(R.string.widget_open))
                return views
            }
            views.setTextViewText(R.id.widget_title, shown.title)
            views.setTextViewText(R.id.widget_artist, shown.artist ?: "")
            views.setViewVisibility(
                R.id.widget_artist,
                if (shown.artist.isNullOrEmpty()) View.GONE else View.VISIBLE,
            )
            views.setContentDescription(
                R.id.widget_root,
                listOfNotNull(shown.title, shown.artist).joinToString(", "),
            )

            views.setViewVisibility(R.id.widget_play_pause, View.VISIBLE)
            views.setImageViewResource(
                R.id.widget_play_pause,
                if (shown.playing) R.drawable.ic_widget_pause else R.drawable.ic_widget_play,
            )
            views.setContentDescription(
                R.id.widget_play_pause,
                context.getString(if (shown.playing) R.string.widget_pause else R.string.widget_play),
            )
            views.setOnClickPendingIntent(R.id.widget_play_pause, button(context, ACTION_PLAY_PAUSE))

            // Skips that can't happen are hidden, as in the notification.
            views.setViewVisibility(
                R.id.widget_previous,
                if (shown.canGoPrevious) View.VISIBLE else View.INVISIBLE,
            )
            views.setOnClickPendingIntent(R.id.widget_previous, button(context, ACTION_PREVIOUS))
            views.setViewVisibility(
                R.id.widget_next,
                if (shown.canGoNext) View.VISIBLE else View.INVISIBLE,
            )
            views.setOnClickPendingIntent(R.id.widget_next, button(context, ACTION_NEXT))
            return views
        }

        /** Sizes the cover, text and buttons to the widget, so a bigger widget gets bigger controls. */
        @androidx.annotation.RequiresApi(Build.VERSION_CODES.S)
        private fun fit(views: RemoteViews, layout: Int, size: SizeF) {
            val w = size.width
            val h = size.height
            val (art, skip, title) = when (layout) {
                // The three buttons take about 3.2 times a skip button's
                // width, and are kept from crowding out the title.
                R.layout.widget_now_playing -> {
                    val cover = (h - 16f).coerceIn(40f, 96f)
                    val room = (w - 16f - cover - 12f - ROW_TEXT_MIN) / 3.2f
                    Triple(
                        cover,
                        minOf(h * 0.6f, room).coerceIn(36f, 56f),
                        if (h >= 80f) 16f else 14f,
                    )
                }
                R.layout.widget_now_playing_large -> {
                    val cover = minOf(h - 24f, w * 0.42f).coerceIn(72f, 240f)
                    val room = (w - 24f - cover - 16f - 32f) / 3.2f
                    Triple(
                        cover,
                        minOf(h * 0.26f, room).coerceIn(40f, 64f),
                        (h / 9f).coerceIn(16f, 24f),
                    )
                }
                // The square's cover fills it; only the controls scale.
                else -> {
                    val side = minOf(w, h)
                    Triple(0f, (side * 0.2f).coerceIn(40f, 64f), (side / 11f).coerceIn(14f, 22f))
                }
            }
            if (art > 0f) {
                views.setViewLayoutWidth(R.id.widget_art, art, TypedValue.COMPLEX_UNIT_DIP)
                views.setViewLayoutHeight(R.id.widget_art, art, TypedValue.COMPLEX_UNIT_DIP)
            }
            views.setTextViewTextSize(R.id.widget_title, TypedValue.COMPLEX_UNIT_SP, title)
            views.setTextViewTextSize(R.id.widget_artist, TypedValue.COMPLEX_UNIT_SP, title - 2f)
            val play = skip * 1.2f
            for ((id, side) in listOf(
                R.id.widget_previous to skip,
                R.id.widget_next to skip,
                R.id.widget_play_pause to play,
            )) {
                views.setViewLayoutWidth(id, side, TypedValue.COMPLEX_UNIT_DIP)
                views.setViewLayoutHeight(id, side, TypedValue.COMPLEX_UNIT_DIP)
            }
            // The icons fill the buttons less the padding, so they grow with them.
            val density = Resources.getSystem().displayMetrics.density
            val skipPad = (skip * 0.2f * density).toInt()
            val playPad = (play * 0.25f * density).toInt()
            views.setViewPadding(R.id.widget_previous, skipPad, skipPad, skipPad, skipPad)
            views.setViewPadding(R.id.widget_next, skipPad, skipPad, skipPad, skipPad)
            views.setViewPadding(R.id.widget_play_pause, playPad, playPad, playPad, playPad)
        }

        private fun openApp(context: Context): PendingIntent {
            val intent = (
                context.packageManager.getLaunchIntentForPackage(context.packageName)
                    ?: Intent(context, MainActivity::class.java)
                ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            return PendingIntent.getActivity(
                context,
                0,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }

        private fun button(context: Context, action: String): PendingIntent =
            PendingIntent.getBroadcast(
                context,
                action.hashCode(),
                Intent(context, WidgetButtonReceiver::class.java).setAction(action),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )

        /** The cover from the artwork cache, scaled down; only ever a file there. */
        private fun cover(context: Context, path: String): Bitmap? {
            artCache?.let { (cached, bitmap) -> if (cached == path) return bitmap }
            val bitmap = decode(context, path)
            artCache = path to bitmap
            return bitmap
        }

        private fun decode(context: Context, path: String): Bitmap? {
            val file = File(path)
            val dir = File(context.cacheDir, "artwork")
            if (file.parentFile?.canonicalPath != dir.canonicalPath || !file.isFile) return null
            return try {
                val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                BitmapFactory.decodeFile(file.path, bounds)
                var sample = 1
                while (bounds.outWidth / (sample * 2) >= ART_SIZE &&
                    bounds.outHeight / (sample * 2) >= ART_SIZE
                ) {
                    sample *= 2
                }
                val decoded = BitmapFactory.decodeFile(
                    file.path,
                    BitmapFactory.Options().apply { inSampleSize = sample },
                ) ?: return null
                val longest = maxOf(decoded.width, decoded.height)
                if (longest <= ART_SIZE) return decoded
                val scale = ART_SIZE.toFloat() / longest
                Bitmap.createScaledBitmap(
                    decoded,
                    (decoded.width * scale).toInt().coerceAtLeast(1),
                    (decoded.height * scale).toInt().coerceAtLeast(1),
                    true,
                )
            } catch (e: Exception) {
                Log.w("OAmp", "Widget cover not readable", e)
                null
            } catch (e: OutOfMemoryError) {
                null
            }
        }
    }
}
