package dev.oamp.oamp

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Build
import android.util.Log
import android.util.SizeF
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
                    val views = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                        // The launcher picks the biggest layout that fits.
                        RemoteViews(
                            mapOf(
                                SizeF(180f, 40f) to build(app, R.layout.widget_now_playing, shown, art),
                                SizeF(180f, 110f) to
                                    build(app, R.layout.widget_now_playing_square, shown, art),
                            ),
                        )
                    } else {
                        build(app, R.layout.widget_now_playing, shown, art)
                    }
                    manager.updateAppWidget(all, views)
                } catch (e: RuntimeException) {
                    Log.w("OAmp", "Home screen widget not updated", e)
                }
            }
        }

        private fun build(context: Context, layout: Int, shown: State?, art: Bitmap?): RemoteViews {
            val views = RemoteViews(context.packageName, layout)
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
