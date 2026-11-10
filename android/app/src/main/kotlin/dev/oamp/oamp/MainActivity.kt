package dev.oamp.oamp

import android.Manifest
import android.content.pm.PackageManager
import android.net.wifi.WifiManager
import android.os.Build
import android.util.Log
import com.ryanheise.audioservice.AudioServiceActivity
import com.ryanheise.audioservice.OampForeground
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * AudioServiceActivity (from audio_service) shares its Flutter engine with the
 * background media service, so playback, the notification and the lock screen
 * controls keep working when the activity goes away.
 */
class MainActivity : AudioServiceActivity() {
    private var pendingPermission: MethodChannel.Result? = null
    private var multicastLock: WifiManager.MulticastLock? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "oamp/notifications")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "requestPermission" -> requestNotificationPermission(result)
                    "keepForegroundWhilePaused" -> {
                        OampForeground.setKeepWhilePaused(call.arguments == true)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        // A foreground service with a progress notification, so downloads
        // carry on with the screen off.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "oamp/downloads")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "show" -> {
                        // Android refuses to start a service from the
                        // background at times; downloading goes on regardless.
                        val started = try {
                            DownloadService.show(
                                applicationContext,
                                call.argument<Int>("done") ?: 0,
                                call.argument<Int>("total") ?: 0,
                            )
                            true
                        } catch (e: RuntimeException) {
                            Log.w("OAmp", "Download notification refused", e)
                            false
                        }
                        result.success(started)
                    }
                    "hide" -> {
                        DownloadService.hide(applicationContext)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        // Wi-Fi drops multicast unless an app holds a lock, so it is held
        // while OAmp looks for speakers and TVs.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "oamp/network")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "acquireMulticastLock" -> {
                        multicastLock().acquire()
                        result.success(null)
                    }
                    "releaseMulticastLock" -> {
                        multicastLock?.takeIf { it.isHeld }?.release()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun multicastLock(): WifiManager.MulticastLock =
        multicastLock ?: (applicationContext.getSystemService(WIFI_SERVICE) as WifiManager)
            .createMulticastLock("oamp-discovery")
            .apply { setReferenceCounted(true) }
            .also { multicastLock = it }

    /** Android 13+ asks before an app may post notifications; older versions just allow it. */
    private fun requestNotificationPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            result.success(true)
            return
        }
        if (pendingPermission != null) {
            result.success(false)
            return
        }
        pendingPermission = result
        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), NOTIFICATIONS_REQUEST)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != NOTIFICATIONS_REQUEST) return
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        pendingPermission?.success(granted)
        pendingPermission = null
    }

    companion object {
        private const val NOTIFICATIONS_REQUEST = 4201
    }
}
