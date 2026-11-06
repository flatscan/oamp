# OAmp branding

OAmp's mark is a coral ring (the O) with a sound wave inside, on the app's
near-black canvas. Coral is `#FF6B4A`, the same accent as `lib/ui/theme.dart`.

| File | Use |
| --- | --- |
| `oamp-icon.svg` | Full app icon, used for 40 px and up |
| `oamp-icon-small.svg` | Simplified icon (thicker ring, five bars) for 32 px and below |
| `oamp-glyph.svg` | White one-colour mark, as used for the Android notification icon |

All platform icon files are generated from `generate.py`, so change the shapes
there and rerun it rather than editing the outputs:

```
pip install pillow cairosvg
python3 branding/generate.py
```

It writes:

- `windows/runner/resources/app_icon.ico` (exe, taskbar, Start menu, installer)
- `android/app/src/main/res/mipmap-*/ic_launcher.png` (launcher icon before Android 8)
- `android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml` with
  `drawable/ic_launcher_foreground.xml`, `drawable/ic_launcher_monochrome.xml`
  (themed icons on Android 13+) and `values/ic_launcher_colors.xml`
- `android/app/src/main/res/drawable/ic_stat_oamp.xml` (notification icon)
