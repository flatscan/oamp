# Contributing to OAmp

Thanks for your interest in OAmp. It's a small project run by one person, so
the best way to help right now is to use it and report what you find.

## Reporting a bug or asking for a feature

Open an issue at <https://github.com/flatscan/oamp/issues> and pick the bug
report or feature request form. For bugs, the form asks for your OAmp version,
your device and its Windows or Android version, and your server version, which
makes problems much quicker to track down.

Before asking for a feature, check the roadmap in the
[README](README.md#whats-next); it may already be planned.

OAmp is a player, not a library manager. It will never edit or delete your
music files or their tags and artwork; use your server's own interface for
that. Your own data, such as playlists, ratings, favourites and the play
queue, is fine.

## Security problems

Please don't report security problems in a public issue. See
[SECURITY.md](SECURITY.md).

## Code contributions

Please open an issue before starting on a pull request, so we can agree on the
approach first. Unasked-for pull requests may not be merged, even good ones,
if they don't fit the plan.

When you do send one:

- Branch from `dev` and target `dev`. `main` only changes when a release is
  made.
- Keep it to one change, with a clear title.
- Run `flutter analyze` and `flutter test` before you push. CI runs both and
  builds Windows and Android.
- Fill in the pull request template, including how you tested it.
- Pull requests are squash-merged.

How the code is organised is described in
[docs/architecture.md](docs/architecture.md), and the build steps are in the
[README](README.md#building-from-source).

## Licence

OAmp is licensed under the [GNU General Public License v3.0](LICENSE). By
contributing, you agree that your contribution is licensed under the same
terms.

## Code of conduct

Everyone taking part is expected to follow the
[code of conduct](CODE_OF_CONDUCT.md).
