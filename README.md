# OAmp

OAmp is an open source music player for [Navidrome](https://www.navidrome.org/).
It is built to just work: sign in to your server and start listening, with
little to set up and nothing to fiddle with.

It runs on Windows and Android. The layout is a tall single column on every
device, the same on a desktop as on a phone: browse your library above, a
mini-player along the bottom, and a full now playing screen one tap away.

> **Status: alpha.** [v1.0.0-Alpha1](https://github.com/flatscan/oamp/releases/tag/v1.0.0-Alpha1)
> is the first public release. It is ready for people happy to try things out
> and report problems, so expect some rough edges.

## Download

Get the latest build from the
[Releases page](https://github.com/flatscan/oamp/releases).

| Platform | File | |
| --- | --- | --- |
| Windows 10/11 (x64) | `oamp-<version>-windows-setup.exe` | Installer. Installs for your user, no admin needed. |
| Windows 10/11 (x64) | `oamp-<version>-windows.zip` | Portable. Unzip anywhere and run `oamp.exe`. |
| Android 7.0 or later | `oamp-<version>.apk` | Side-load it on your phone. |

You need a Navidrome server, **v0.64.2 or later**. Plain `http://` addresses on
your home network work fine. To listen away from home, reach your server
through a VPN such as Tailscale, or over HTTPS.

### Installing on Windows

Run the installer and open OAmp from the Start menu. The installer adds OAmp
to *Settings → Apps*, upgrades an existing install in place, and keeps your
sign-in and settings if you uninstall and reinstall.

OAmp isn't code-signed yet, so Windows SmartScreen may say "Windows protected
your PC" the first time. Click **More info**, then **Run anyway**. Signed
builds are planned for a later release.

### Installing on Android

Download the APK on your phone and tap it. Android asks once to allow installs
from your browser or file manager; allow it, then open **OAmp** from the app
drawer. Later releases install over the top and keep your sign-in.

If you installed a test build from GitHub Actions before, uninstall it once
first. Test builds are signed with a different key, so Android won't install a
release over one. You'll need to sign in again afterwards.

## What it does

- **Simple sign-in** with your server address and either your username and
  password or a Navidrome API key. OAmp uses token sign-in, so your password
  is never sent or stored, and the sign-in is kept in the system's secure
  store.
- **Home** with one-tap *Shuffle library* and *Liked tracks*, then rows of
  recently played, recently added, most played, liked and random albums.
- **Library**: artists and albums with an A to Z jump bar, playlists you can
  create, rename and reorder, and liked tracks. Stays quick with libraries of
  thousands of albums.
- **Search** across artists, albums and tracks as you type, with filters and
  recent searches.
- **Now playing**, tinted from the cover art, with the queue underneath: drag
  to reorder, swipe to remove, tap to jump. Your queue is saved on the server,
  so you can pick up on another device where you left off.
- **Lyrics** (synced where your server has them), **star ratings** and likes
  for tracks, albums and artists, and **track radio**.
- **Playback settings**: gapless playback (Windows), crossfade, ReplayGain,
  streaming quality (with a separate setting for mobile data on Android), and a
  cache that loads the next tracks ahead of time.
- **Plays are reported** to Navidrome, so play counts and "recently played"
  stay current.

On **Windows**, OAmp opens as a tall, narrow window where you last left it. The mode button switches
to expanded mode, which adds a library panel beside the column. OAmp shows up
in the Windows media overlay and on the lock screen, the keyboard's media keys
work while it's minimised, and there are shortcuts for the basics: `Space` to
play or pause, `Ctrl+←`/`Ctrl+→` to skip, `Ctrl+↑`/`Ctrl+↓` for volume and
`Ctrl+F` to search.

On **Android**, it keeps playing in the background with notification, lock
screen, Bluetooth and headset controls, pauses for calls and other apps, pauses when headphones are
unplugged, recovers when the network drops, and has a landscape layout for now
playing.

## What's next

Alpha2 is in the works. Planned so far:

- Offline downloads, with playlists that stay in sync
- Endless play: keep going after the queue ends, with the next album by the
  same artist or similar tracks
- An equaliser with simple presets that suit your device
- More than one server, a backup address for when you're away from home, and
  other server types such as Jellyfin and Plex
- Android home screen widgets
- Player controls in the Windows taskbar preview
- An option for expanded mode to open to the left, so the window can sit
  against the right edge of the screen

Also on the list: Android Auto, CarPlay, Chromecast, Linux and a web version. macOS and iOS
versions are on hold for now.

## Reporting problems

Please open an issue at <https://github.com/flatscan/oamp/issues>. It helps to
include your OAmp version, your device and its Windows or Android version, and
your Navidrome version.

## How OAmp is built

OAmp was developed with significant augmented assistance provided by
[Claude](https://claude.ai), Anthropic's AI assistant. Ed Jackson directs the
project, sets the design and tests every change; much of the code was written
with Claude.

## Building from source

OAmp is a [Flutter](https://flutter.dev/) app. How the code is organised, and
how it leaves room for the features above, is described in
[docs/architecture.md](docs/architecture.md). Release signing is covered in
[docs/signing.md](docs/signing.md).

### Windows

1. **Install Git** from <https://git-scm.com/download/win>.
2. **Install Visual Studio 2022** (Community is fine; this is not VS Code)
   from <https://visualstudio.microsoft.com/downloads/>, with the
   **Desktop development with C++** workload. Flutter needs its C++ compiler
   and Windows SDK to build desktop apps.
3. **Turn on Developer Mode** in *Settings → System → For developers*.
   Flutter plugins need the symlink support it enables.
4. **Install Rust** with `winget install Rustlang.Rustup` (or from
   <https://rustup.rs>), then open a new terminal. The Windows media overlay
   package, [`smtc_windows`](https://pub.dev/packages/smtc_windows), is
   written in Rust and compiled during the build. Keep `flutter_rust_bridge`
   at the version pinned in `pubspec.yaml`: a newer one builds but fails at
   launch.
5. **Install the Flutter SDK** by following
   <https://docs.flutter.dev/get-started/install/windows/desktop>. Put it in a
   folder without spaces, such as `C:\dev\flutter`, and add its `bin` folder to
   your PATH. If you use VS Code, its **Flutter** extension can download the
   SDK for you.
6. **Check the setup** in a new terminal with `flutter doctor`. The *Flutter*
   and *Visual Studio - develop Windows apps* lines should be green.
7. **Get the code and run it:**

   ```powershell
   git clone https://github.com/flatscan/oamp.git
   cd oamp
   flutter pub get
   flutter run -d windows
   ```

   In VS Code, pick **Windows (windows-x64)** as the device and press `F5`.

To build a release:

```powershell
flutter build windows --release
```

The app is written to `build\windows\x64\runner\Release\`. `oamp.exe` needs the
DLLs and `data` folder next to it, so copy the whole folder. The Visual C++
runtime is bundled, so nothing else needs installing.

To build the installer, install [Inno Setup](https://jrsoftware.org/isdl.php)
6.3 or later and run this after the release build:

```powershell
& "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" windows\installer\oamp.iss
```

It writes `build\installer\oamp-<version>-setup.exe`.

### Android

Install Android Studio (for the Android SDK) and JDK 17, then:

```sh
flutter build apk --release
```

The APK is written to `build/app/outputs/flutter-apk/app-release.apk`. With a
phone connected and USB debugging on, `flutter run -d android` runs a debug
build on it.

### Checks

```sh
flutter analyze
flutter test
dart format lib test
```

CI runs these on every pull request and builds the Windows app, installer and
an Android APK as downloadable artifacts. These test APKs are signed with a
public side-load key kept in the repo (`android/app/sideload.keystore`), so
each one installs over the last. Pushing a `v*` tag builds release-signed
files and drafts a GitHub release from `docs/releases/<tag>.md`.

## License

OAmp is free software under the GNU General Public License v3.0. See
[LICENSE](LICENSE).
