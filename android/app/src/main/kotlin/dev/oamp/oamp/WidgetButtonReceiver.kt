package dev.oamp.oamp

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.support.v4.media.session.MediaControllerCompat
import android.util.Log
import com.ryanheise.audioservice.OampSession

/**
 * The home screen widget's previous, play/pause and next buttons
 * (NowPlayingWidget.kt). Not exported: only the widget's own buttons can
 * reach it. Presses go to the media session, as the notification's do.
 */
class WidgetButtonReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val shown = NowPlayingWidget.state
        val token = OampSession.token()
        if (shown == null || token == null) {
            // The app was closed since the widget was drawn.
            NowPlayingWidget.clear(context)
            return
        }
        try {
            val controls = MediaControllerCompat(context, token).transportControls
            when (intent.action) {
                // What the widget shows is what the press is about.
                NowPlayingWidget.ACTION_PLAY_PAUSE ->
                    if (shown.playing) controls.pause() else controls.play()
                NowPlayingWidget.ACTION_NEXT -> controls.skipToNext()
                NowPlayingWidget.ACTION_PREVIOUS -> controls.skipToPrevious()
            }
        } catch (e: RuntimeException) {
            Log.w("OAmp", "Widget button not delivered", e)
        }
    }
}
