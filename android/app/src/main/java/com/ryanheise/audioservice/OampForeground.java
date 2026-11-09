package com.ryanheise.audioservice;

import android.app.Service;
import android.os.PowerManager;
import java.lang.reflect.Field;

/**
 * Keeps audio_service's media service in the foreground while paused, for
 * as long as a speaker or TV is playing. audio_service only offers this as
 * a setting fixed at start-up, so this sits in its package to reach the
 * running service.
 */
public final class OampForeground {
    private OampForeground() {}

    public static void setKeepWhilePaused(boolean keep) {
        AudioService service = AudioService.instance;
        if (service == null) return;
        AudioServiceConfig config = service.getConfig();
        if (config == null) return;
        // Not saved, so the next start of the service uses OAmp's setting.
        config.androidStopForegroundOnPause = !keep;
        if (!keep && !service.isPlaying()) {
            // What audio_service does itself when playback pauses.
            service.stopForeground(Service.STOP_FOREGROUND_DETACH);
            releaseWakeLock(service);
        }
    }

    private static void releaseWakeLock(AudioService service) {
        try {
            Field field = AudioService.class.getDeclaredField("wakeLock");
            field.setAccessible(true);
            PowerManager.WakeLock lock = (PowerManager.WakeLock) field.get(service);
            if (lock != null && lock.isHeld()) lock.release();
        } catch (ReflectiveOperationException | RuntimeException e) {
            // audio_service releases it at the next pause.
        }
    }
}
