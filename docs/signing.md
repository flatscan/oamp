# Signing

## Android

OAmp uses three Android keys.

| Key | Signs | Where it lives |
| --- | --- | --- |
| Side-load (`android/app/sideload.keystore`) | CI test builds from pull requests and `main` | In the repo. It is public, so nothing published may be signed with it. |
| Release (`oamp-release`) | GitHub release APKs; given to Google Play as the app signing key | Maintainer's password manager plus an offline backup, and GitHub secrets |
| Upload (`oamp-upload`) | Bundles uploaded to Google Play | Maintainer's password manager and GitHub secrets. Google can reset it. |

Using one release key for GitHub and Google Play means people can move
between the two without reinstalling. A release-signed APK cannot install
over a side-load test build: uninstall the test build once first.

### Making the keys (once)

On a trusted Windows PC with Android Studio and the GitHub CLI signed in:

```powershell
powershell -ExecutionPolicy Bypass -File android\signing\new-release-keys.ps1 -SetSecrets
```

The script writes `oamp-release.p12`, `oamp-upload.p12` and `passwords.txt`
to `%USERPROFILE%\oamp-signing`, and stores these repository secrets:

- `OAMP_RELEASE_KEYSTORE_BASE64`, `OAMP_RELEASE_KEYSTORE_PASSWORD`,
  `OAMP_RELEASE_KEY_ALIAS`, `OAMP_RELEASE_KEY_PASSWORD`
- `OAMP_UPLOAD_KEYSTORE_BASE64`, `OAMP_UPLOAD_KEYSTORE_PASSWORD`,
  `OAMP_UPLOAD_KEY_ALIAS`, `OAMP_UPLOAD_KEY_PASSWORD`

Then move the passwords into a password manager, copy the folder to an
offline backup, and delete `passwords.txt`.

### Google Play

When creating the app in Play Console, choose to use your own app signing
key instead of a Google-generated one, and follow Play Console's steps to
export `oamp-release` with the PEPK tool. Register `oamp-upload` as the
upload key.

### Releasing

Write the release notes in `docs/releases/<tag>.md` (for example
`docs/releases/v1.0.0-Alpha1.md`), merge them, then push a tag such as
`v1.0.0`. The `Release` workflow builds the APK with the release key (and the
Play bundle with the upload key, when its secrets exist), builds the Windows
installer and a zip of the app, and creates a draft GitHub release for the
tag with the APK, installer and zip attached. Tags with a suffix, such as
`-Alpha1`, are marked as pre-releases. Review the draft on GitHub and press
Publish. The Android build fails rather than fall back to the side-load key.

## Windows

Planned: signing through the SignPath Foundation programme for open source
projects. Until then the Windows exe and installer are unsigned.
