# OAmp

An open source music player for [Navidrome](https://www.navidrome.org/),
built with Flutter. It talks to your server over the Subsonic / OpenSubsonic
API and uses a tall, single-column layout: browse above, a mini-player along
the bottom, and a full now playing screen one click away.

Windows is the first target. macOS, Android and iOS build from the same code.

> Status: early prototype. Sign in, browse and search the library, play,
> manage the queue, like tracks, and control playback from the Windows media
> overlay and media keys. See the [design doc](https://claude.ai/artifact/KijCrsNp8q1eTdPPqadg3i)
> for the v1 plan.

## Features so far

- Sign in with server URL, username and password. OAmp uses Subsonic token
  auth (`t = md5(password + salt)`), so the password is never sent or stored.
  The token, salt, URL and username are kept in the OS secure store (Windows
  Credential Manager, macOS/iOS Keychain, Android Keystore).
- **Home:** one-click *Shuffle library* and *Liked tracks*, then rows of
  recently played, recently added, most played, liked and random albums.
- **Library:** artists A to Z, every album (sortable, loaded as you scroll),
  playlists and liked tracks. Artist pages play or shuffle everything by the
  artist; album pages group tracks by disc.
- **Search** across artists, albums and tracks as you type.
- **Mini-player** above the tabs. Click it (or swipe up) for **now playing**:
  large artwork on a background tinted from the cover, seek bar, repeat,
  shuffle up next, like, volume, and links to the artist and album. Swipe the
  artwork sideways to skip. *Up next* swaps the artwork for the queue: click to
  jump, drag to reorder, swipe or click to remove, clear.
- Right-click (or long-press) any track for play next, add to queue, like,
  go to album and go to artist.
- Plays are reported to the server (scrobbles), so Navidrome's play counts and
  "recently played" stay current.
- One tall column on every platform, the same as on a phone. On Windows the
  window has its own dark title bar. Its sidebar button opens a library fly-out
  to the right of the column and widens the window; while it is open the
  column shows now playing and browsing moves into the fly-out.
- Keyboard: `Space` play/pause, `Ctrl+←`/`Ctrl+→` previous/next,
  `Ctrl+↑`/`Ctrl+↓` volume, `Ctrl+F` search, `Esc` closes now playing, and the
  mouse's back button goes back.
- On Windows, keeps playing in the background and shows up in the Windows
  media overlay (the panel next to the volume flyout, and the lock screen)
  with title, artist, album, cover and play/pause, next and previous. The
  keyboard's media keys control OAmp even when its window is minimised.

## Setting up on Windows with VS Code

1. **Install Git** from <https://git-scm.com/download/win> if you don't have it.
2. **Install Visual Studio 2022** (Community is fine, this is not VS Code)
   from <https://visualstudio.microsoft.com/downloads/>. In the installer tick
   the **Desktop development with C++** workload. Flutter needs its C++
   compiler and Windows SDK to build desktop apps.
3. **Turn on Developer Mode**: Settings → System → For developers →
   Developer Mode. Flutter plugins need symlink support, which this enables.
4. **Install VS Code** from <https://code.visualstudio.com/> and then the
   **Flutter** extension (it installs the Dart extension too).
5. **Install Rust.** The Windows media overlay package
   ([`smtc_windows`](https://pub.dev/packages/smtc_windows)) is written in
   Rust and compiled during the Windows build. In a terminal run
   `winget install Rustlang.Rustup`, or use the installer from
   <https://rustup.rs>, then open a new terminal. You only need to do this once.
6. **Install the Flutter SDK.** The easiest way is from VS Code: open the
   Command Palette (`Ctrl+Shift+P`), run **Flutter: New Project**, and when it
   says the SDK is missing choose **Download SDK**. Pick a folder without
   spaces or admin rights, such as `C:\dev\flutter`, and let it add Flutter to
   your PATH. (You can cancel the new-project step afterwards.)

   To do it by hand instead, follow
   <https://docs.flutter.dev/get-started/install/windows/desktop>, unzip the
   SDK to `C:\dev\flutter` and add `C:\dev\flutter\bin` to your user PATH.
7. **Check the install.** Open a new terminal and run:

   ```powershell
   flutter doctor
   ```

   The *Flutter* and *Visual Studio - develop Windows apps* lines should be
   green. Android and Chrome warnings can be ignored for now.
8. **Get the code and its packages:**

   ```powershell
   git clone https://github.com/flatscan/oamp.git
   cd oamp
   flutter pub get
   code .
   ```
9. **Run it.** In VS Code pick **Windows (windows-x64)** as the device in the
   status bar, then press `F5` (or choose *OAmp (Windows)* in the Run and Debug
   panel). From a terminal, `flutter run -d windows` does the same.

To build a release `.exe`:

```powershell
flutter build windows --release
```

The app ends up in `build\windows\x64\runner\Release\`. Copy that whole folder
to share it; `oamp.exe` needs the DLLs and `data` folder next to it.

## Other platforms

| Platform | Needs | Run |
| --- | --- | --- |
| macOS | Xcode and CocoaPods | `flutter run -d macos` |
| Android | Android Studio (for the SDK) and a device or emulator | `flutter run -d android` |
| iOS | A Mac with Xcode, CocoaPods and a device or simulator | `flutter run -d ios` |

Plain `http://` servers on your LAN are allowed on every platform. Background
playback and lock-screen controls are wired up on Windows only so far; Android,
iOS and macOS get them through `audio_service` in a later milestone. On macOS the secure-storage package may need the Keychain Sharing
capability added in Xcode before sign-in persists.

## Project layout

```
lib/
  main.dart                 App entry: audio backend, desktop window, routing
  core/                     Backend-neutral, no dart:io
    models.dart             Artist, Album, Track, Playlist (OAmp's own models)
    music_source.dart       MusicSource interface + capability flags
    track_resolver.dart     Track -> playable URI (stream now, downloads in v2)
  sources/subsonic/         The only v1 MusicSource: Navidrome / Subsonic
    subsonic_client.dart    Transport and token auth
    subsonic_source.dart    Maps Subsonic JSON to OAmp models
  audio/
    audio_engine.dart       AudioEngine output interface + just_audio engine
  platform/                 Platform code behind interfaces
    secure_store.dart       SecureStore (OS keychain)
    platform_info.dart      isDesktop without dart:io
    system_controls.dart    SystemControls: the OS media session interface
    windows_system_controls.dart   SMTC: media overlay and media keys
    platform_system_controls.dart  Picks the implementation per platform
  state/                    Riverpod providers
    session.dart            ServerSession keyed by serverId, sign-in
    library.dart            Cached library queries
    player.dart             PlayerController: the queue; engine is its output
    playback_reporter.dart  Reports now playing and plays to the server
    system_controls_bridge.dart  Mirrors the player into SystemControls
  ui/
    app_frame.dart          Window bar and keyboard shortcuts around every screen
    login_screen.dart
    home_shell.dart         Single column with mini-player, desktop fly-out
    browser.dart            Home / Library / Search tabs, each with its history
    browse/                 Home, library, search, album, artist, playlist pages
    player/                 Mini-player, now playing, queue, controls
    widgets.dart            Shared rows, cards and the track menu
test/
  fakes/                    FakeMusicSource, FakeAudioEngine, FakeSystemControls
  system_controls_test.dart Media keys and overlay, driven through fakes
  ui_with_fake_source_test.dart  Drives the whole UI with no server
  player_test.dart          Queue, repeat, shuffle, volume and play reports
  architecture_test.dart    Enforces the seams below
```

### Built for v2

The design doc's v2 goals plug into seams that already exist, so they add
implementations rather than rewrite v1:

- **Other backends (Jellyfin, Plex):** a new `MusicSource`. The UI and
  providers only see `core/` models.
- **Multiple servers:** credentials are stored per `serverId`, and the
  active one is a `ServerSession`. A switcher only changes which is active.
- **Offline downloads:** a `TrackResolver` that returns a local file when
  the track is downloaded.
- **Chromecast:** `PlayerController` owns the queue and sends it to an
  `AudioEngine`, so a cast engine is another output.
- **Linux and web:** platform code sits behind `AudioEngine`, `SecureStore`,
  `SystemControls` and `platform_info`. `architecture_test.dart` fails if
  `lib/ui` imports the Subsonic or audio code, if core, state or UI import
  `dart:io`, or if anything outside `lib/platform` touches a media session
  package.
- **Lock screens, CarPlay and Android Auto:** the player talks to the OS only
  through `SystemControls`, and OS buttons call the same `PlayerController`
  methods as the app's own. Android, iOS and macOS add an `audio_service`
  implementation, and Linux an MPRIS one, as new files in `lib/platform`.

### Packages

- [`just_audio`](https://pub.dev/packages/just_audio) for playback, with
  [`just_audio_media_kit`](https://pub.dev/packages/just_audio_media_kit)
  (libmpv) as the Windows backend. All playback goes through
  `AudioEngine`, so the backend can be swapped in one file.
- [`flutter_riverpod`](https://pub.dev/packages/flutter_riverpod) for state.
- [`http`](https://pub.dev/packages/http) and
  [`crypto`](https://pub.dev/packages/crypto) for the API and token auth.
- [`flutter_secure_storage`](https://pub.dev/packages/flutter_secure_storage)
  for saved credentials.
- [`window_manager`](https://pub.dev/packages/window_manager) for the
  phone-shaped desktop window and the library fly-out.
- [`smtc_windows`](https://pub.dev/packages/smtc_windows) for the Windows
  media overlay and media keys (needs Rust to build).

## Development

```sh
flutter analyze
flutter test
dart format lib test
```

CI runs the same checks plus a Windows release build on every pull request,
and uploads the built app as a workflow artifact.

## License

GPL-3.0. See [LICENSE](LICENSE).
