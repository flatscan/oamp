package com.ryanheise.audioservice;

import android.support.v4.media.session.MediaSessionCompat;

/**
 * The running media session, for OAmp's home screen widget, whose buttons
 * go straight to it. audio_service keeps the service instance to itself,
 * so this sits in its package to reach it.
 */
public final class OampSession {
    private OampSession() {}

    /** The session's token, or null when the media service isn't running. */
    public static MediaSessionCompat.Token token() {
        AudioService service = AudioService.instance;
        return service == null ? null : service.getSessionToken();
    }
}
