# How OAmp is organised

OAmp is a Flutter app with [Riverpod](https://riverpod.dev/) for state. The
app talks to the server through a backend-neutral `MusicSource`, plays audio
through an `AudioEngine`, and reaches the operating system only through
interfaces in `lib/platform`. That keeps the UI and state free of server and
platform details, so new servers, outputs and platforms add code rather than
change what is there.

## Project layout

```
lib/
  main.dart                 App entry: audio backend, desktop window, routing
  core/                     Backend-neutral models and interfaces, no dart:io
    models.dart             Artist, Album, Track, Playlist (OAmp's own models)
    music_source.dart       MusicSource interface and capability flags
    play_queue.dart         A saved queue to resume, locally or from the server
    lyrics.dart             Plain and synced lyrics
    artwork_cache.dart      ArtworkCache interface: covers kept on disk
    playback_options.dart   Gapless, crossfade, ReplayGain, quality, cache
    track_cache.dart        TrackCache interface: temporary playback cache
    track_resolver.dart     Track to playable URI (streams now, downloads later)
  sources/subsonic/         The MusicSource for Navidrome and other
                            Subsonic / OpenSubsonic servers
    subsonic_client.dart    Transport and token auth
    subsonic_source.dart    Maps Subsonic JSON to OAmp models
  audio/
    audio_engine.dart       AudioEngine interface; MixingEngine crossfades decks
    mpv_deck.dart           libmpv player (Windows)
    just_audio_deck.dart    just_audio player (Android)
    audio_focus.dart        Pausing and ducking for calls and other apps
    stream_cache.dart       On-disk cache served to the player over loopback
    platform_audio.dart     Picks the player and opens the cache per platform
  platform/                 Platform code behind interfaces
    secure_store.dart       SecureStore (OS keychain)
    preferences.dart        Plain settings (shared_preferences)
    platform_info.dart      Platform checks without dart:io
    system_controls.dart    SystemControls: the OS media session interface
    windows_system_controls.dart   Windows media overlay and media keys
    android_system_controls.dart   Android notification and lock screen
    platform_system_controls.dart  Picks the implementation per platform
    disk_artwork_cache.dart Artwork cache in a folder of image files
    network_monitor.dart    Wi-Fi or mobile data, for streaming quality
    native_window.dart      Window calls handled by the Windows runner
    window_geometry.dart    Remembers where the desktop window was
  state/                    Riverpod providers
    session.dart            ServerSession keyed by serverId, sign-in
    library.dart            Cached library queries
    player.dart             PlayerController: the queue; the engine plays it
    queue_sync.dart         Keeps the queue across restarts and devices
    playback_reporter.dart  Reports now playing and plays to the server
    precache.dart           Fetches the next tracks into the cache
    radio.dart              Track radio
    lyrics.dart             Lyrics for the current track
    settings.dart           Playback, quality, cache and window settings
    system_controls_bridge.dart  Mirrors the player into SystemControls
  ui/
    app_frame.dart          Window bar and keyboard shortcuts
    home_shell.dart         The single column with mini-player, and the
                            expanded-mode library panel
    window_mode.dart        Single-column and expanded mode, window sizes
    mode_switch.dart        The mode switch button and where it sits
    browser.dart            Home, Library and Search tabs, each with history
    browse/                 Home, library, search, album, artist, playlist and
                            settings pages
    player/                 Mini-player, now playing, queue, lyrics, controls
    widgets.dart            Shared rows, cards and the track menu
test/
  fakes/                    FakeMusicSource, FakeAudioEngine, FakeSystemControls
  architecture_test.dart    Enforces the seams described below
  ...                       UI, player, cache, settings and platform tests,
                            all driven through fakes with no server needed
```

`test/mpv_playback_test.dart` plays real audio through libmpv. It runs where
libmpv is installed (`apt install libmpv-dev`) and is skipped on CI.

## Room to grow

Planned features plug into seams that already exist:

- **Other servers (Jellyfin, Plex and so on):** a new `MusicSource`. The UI
  and providers only see the models in `core/`.
- **More than one server:** credentials are stored per `serverId`, and the
  active one is a `ServerSession`. A switcher only changes which is active.
- **Offline downloads:** a `TrackResolver` that returns a local file when the
  track is downloaded. The playback cache (`TrackCache`) is separate: it is
  temporary, evicted oldest first, and never counts as downloaded.
- **Chromecast:** `PlayerController` owns the queue and sends it to an
  `AudioEngine`, so a cast engine is another output.
- **Linux and web:** platform code sits behind `AudioEngine`, `SecureStore`,
  `SystemControls` and `platform_info`. `architecture_test.dart` fails if
  `lib/ui` imports the Subsonic or audio code, if core, state or UI import
  `dart:io`, or if anything outside `lib/platform` touches a media session
  package.
- **CarPlay, Android Auto and Linux media controls:** the player talks to the
  OS only through `SystemControls`, and OS buttons call the same
  `PlayerController` methods as the app's own. Each is a new file in
  `lib/platform`.

## Main packages

- [`media_kit`](https://pub.dev/packages/media_kit) (libmpv) for playback on
  Windows, and [`just_audio`](https://pub.dev/packages/just_audio) on Android.
  All playback goes through `AudioEngine`.
- [`audio_service`](https://pub.dev/packages/audio_service) for Android
  background playback and media controls.
- [`smtc_windows`](https://pub.dev/packages/smtc_windows) for the Windows
  media overlay and media keys (needs Rust to build).
- [`window_manager`](https://pub.dev/packages/window_manager) for the
  desktop window and expanded mode.
- [`flutter_riverpod`](https://pub.dev/packages/flutter_riverpod) for state.
- [`http`](https://pub.dev/packages/http) and
  [`crypto`](https://pub.dev/packages/crypto) for the API and token auth.
- [`flutter_secure_storage`](https://pub.dev/packages/flutter_secure_storage)
  for the sign-in, and
  [`shared_preferences`](https://pub.dev/packages/shared_preferences) for
  settings.
