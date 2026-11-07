# Accessibility

OAmp should be usable by everyone who wants to listen to their music. It's
in alpha, so it isn't there yet, and this page says honestly where it stands.

## What works

- Playback can be controlled without the app open: keyboard media keys and
  the media overlay on Windows, and the notification, lock screen, Bluetooth
  and headset buttons on Android.
- Android touch targets follow the platform's minimum size.

## Known problems

- At large system text sizes (around 130% and above on Android), album grid
  tiles cut off their text.
- Screen reader support (TalkBack, Narrator) hasn't been tested, and some
  buttons may be missing labels.

## Plans

A full accessibility pass, covering screen reader labels and large text on
every screen, is planned for Alpha4, the UI rework and polish release.

## Reporting a barrier

If something in OAmp is hard or impossible for you to use, please
[open an issue](https://github.com/flatscan/oamp/issues/new?template=bug_report.yml)
and say which screen and which assistive technology or setting you use.
Accessibility problems are treated as bugs.
