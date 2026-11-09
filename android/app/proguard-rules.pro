# OampForeground releases audio_service's wake lock by name.
-keepclassmembers class com.ryanheise.audioservice.AudioService {
    android.os.PowerManager$WakeLock wakeLock;
}
