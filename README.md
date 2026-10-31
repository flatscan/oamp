# OAmp

An open source music player for [Navidrome](https://www.navidrome.org/),
built with Flutter. It talks to your server over the Subsonic / OpenSubsonic
API and uses a tall, Plexamp-style layout where the play queue is always on
screen.

Windows is the first target. macOS, Android and iOS build from the same code.

> Status: early scaffold. Sign in, browse artists and albums, play tracks and
> manage the queue. See the [design doc](https://claude.ai/artifact/KijCrsNp8q1eTdPPqadg3i)
> for the v1 plan.

## Features so far

- Sign in with server URL, username and password. OAmp uses Subsonic token
  auth (`t = md5(password + salt)`), so the password is never sent or stored.
  The token, salt, URL and username are kept in the OS secure store (Windows
  Credential Manager, macOS/iOS Keychain, Android Keystore).
- Browse artists, albums (A–Z), an artist's albums, and an album's tracks.
- Play an album, shuffle it, play a track next, or add it to the end of the
  queue.
- Queue panel that is always visible: tap to jump, drag to reorder, swipe or
  click to remove, clear all.
- One tall column on every platform, the same as on a phone: now playing,
  library and queue, with a draggable divider between library and queue.
- On desktop, the sidebar button in the top bar opens a library fly-out to the
  right of the column and widens the window to make room. While it is open the
  column shows large artwork and the queue. Press it again to close it.

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
5. **Install the Flutter SDK.** The easiest way is from VS Code: open the
   Command Palette (`Ctrl+Shift+P`), run **Flutter: New Project**, and when it
   says the SDK is missing choose **Download SDK**. Pick a folder without
   spaces or admin rights, such as `C:\dev\flutter`, and let it add Flutter to
   your PATH. (You can cancel the new-project step afterwards.)

   To do it by hand instead, follow
   <https://docs.flutter.dev/get-started/install/windows/desktop>, unzip the
   SDK to `C:\dev\flutter` and add `C:\dev\flutter\bin` to your user PATH.
6. **Check the install.** Open a new terminal and run:

   ```powershell
   flutter doctor
   ```

   The *Flutter* and *Visual Studio - develop Windows apps* lines should be
   green. Android and Chrome warnings can be ignored for now.
7. **Get the code and its packages:**

   ```powershell
   git clone https://github.com/flatscan/oamp.git
   cd oamp
   flutter pub get
   code .
   ```
8. **Run it.** In VS Code pick **Windows (windows-x64)** as the device in the
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
playback and lock-screen controls are not wired up yet (see the design doc),
and on macOS the secure-storage package may need the Keychain Sharing
capability added in Xcode before sign-in persists.

## Project layout

```
lib/
  main.dart              App entry: audio backend, desktop window, routing
  api/
    subsonic_client.dart Subsonic/OpenSubsonic REST client and token auth
    models.dart          Artist, Album, Track
  audio/
    audio_engine.dart    AudioEngine interface + just_audio implementation
  state/                 Riverpod providers
    session.dart         Sign-in, saved credentials
    library.dart         Cached library queries
    player.dart          Play queue and transport
  ui/
    login_screen.dart
    home_shell.dart      Single column, queue always visible, desktop fly-out
    library/             Artists, albums, album page
    player/              Now playing and queue panel
test/                    Unit tests for the API client
```

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
