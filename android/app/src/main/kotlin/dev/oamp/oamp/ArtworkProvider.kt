package dev.oamp.oamp

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import com.ryanheise.audioservice.AudioServicePlugin
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileNotFoundException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread

/**
 * Cover art for Android Auto, at content://dev.oamp.oamp.artwork/<cover id>
 * (browse lists) or .../file/<cache file name> (what is playing).
 *
 * The car loads browse artwork itself, in its own process, so it can't be
 * given the server's cover URL (it carries the sign-in token) or a file in
 * the app's private cache. Instead it asks here, and the Dart side
 * (OampAudioHandler, on the `oamp/artwork` channel) answers from the
 * artwork cache, fetching from the server on a miss.
 */
class ArtworkProvider : ContentProvider() {
    private val main by lazy { Handler(Looper.getMainLooper()) }

    override fun onCreate() = true

    override fun getType(uri: Uri) = "image/*"

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        if (mode != "r") throw SecurityException("Artwork is read only")
        val segments = uri.pathSegments
        // content://dev.oamp.oamp.artwork/file/<name>: a cover already in the
        // artwork cache, for the now playing card on Android Auto's home
        // screen. Read straight from disk, so it also works on the main
        // thread, where audio_service loads the notification art.
        if (segments.size == 2 && segments[0] == "file") return cachedFile(segments[1], uri)
        val coverArt = uri.lastPathSegment ?: throw FileNotFoundException(uri.toString())
        // Waiting on the main thread from the main thread would never end;
        // only the car (another process, so a binder thread) reads these.
        if (Looper.myLooper() == Looper.getMainLooper()) throw FileNotFoundException(uri.toString())
        val bytes = fetch(coverArt) ?: throw FileNotFoundException(uri.toString())
        val (read, write) = ParcelFileDescriptor.createPipe()
        thread(name = "oamp-artwork") {
            try {
                ParcelFileDescriptor.AutoCloseOutputStream(write).use { it.write(bytes) }
            } catch (_: Exception) {
                // The car stopped reading, such as when the list scrolled on.
            }
        }
        return read
    }

    private fun cachedFile(name: String, uri: Uri): ParcelFileDescriptor {
        // Only DiskArtworkCache's own file names, never a path.
        if (!CACHED_NAME.matches(name)) throw FileNotFoundException(uri.toString())
        val dir = context?.cacheDir ?: throw FileNotFoundException(uri.toString())
        val file = File(File(dir, "artwork"), name)
        if (!file.isFile) throw FileNotFoundException(uri.toString())
        return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
    }

    /** Asks the Dart side for the image, waiting a while for a slow server. */
    private fun fetch(coverArt: String): ByteArray? {
        val engine = FlutterEngineCache.getInstance().get(AudioServicePlugin.getFlutterEngineId())
            ?: return null
        val result = AtomicReference<ByteArray?>()
        val done = CountDownLatch(1)
        main.post {
            MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
                .invokeMethod("artwork", coverArt, object : MethodChannel.Result {
                    override fun success(value: Any?) {
                        result.set(value as? ByteArray)
                        done.countDown()
                    }

                    override fun error(code: String, message: String?, details: Any?) {
                        done.countDown()
                    }

                    override fun notImplemented() {
                        done.countDown()
                    }
                })
        }
        done.await(TIMEOUT_SECONDS, TimeUnit.SECONDS)
        return result.get()
    }

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): Cursor? = null

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null

    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<out String>?,
    ) = 0

    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?) = 0

    companion object {
        private const val CHANNEL = "oamp/artwork"
        private const val TIMEOUT_SECONDS = 15L
        private val CACHED_NAME = Regex("^[0-9a-f]{40}\\.art$")
    }
}
