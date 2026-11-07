# Security policy

## Supported versions

OAmp is in alpha. Only the latest release on the
[releases page](https://github.com/flatscan/oamp/releases) gets security
fixes.

## Reporting a vulnerability

Please report security problems privately, not in a public issue. Use
GitHub's private reporting: open the repository's
[Security tab](https://github.com/flatscan/oamp/security) and choose
**Report a vulnerability**.

If you can't use GitHub, email <flatscan@pm.me> instead. You can encrypt
your report with the PGP key in
[docs/maintainer-pgp-key.asc](docs/maintainer-pgp-key.asc) (fingerprint
`0319 8CDD 7C5B BDC2 B598 4D1C B17C 3FA1 E253 7E34`).

Please include what you found, how to reproduce it, and which OAmp version and
platform you used. You should get a first reply within a week. OAmp is a
spare-time project, so a fix may take longer, but you'll be kept informed.

## Scope

OAmp is a client: it stores your server address and a sign-in token on your
device and talks to your music server. Problems in OAmp itself are in scope,
for example credentials stored or sent insecurely. Problems in the server
software (Navidrome or others) should be reported to that project.
