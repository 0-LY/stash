# Security

## Reporting a vulnerability

Please report security problems privately through GitHub:
**[Report a vulnerability](https://github.com/0-LY/stash/security/advisories/new)**
(Security tab → Report a vulnerability). Don't open a public issue for security problems.

Include what you found, how to reproduce it and which version of Stash you use
(shown at the bottom of Stash's settings window). You'll get a reply within a few days.

## Supported versions

Only the latest stable release and the latest beta get security fixes. Stash updates itself,
so keeping automatic updates on is the easiest way to stay current.

## How updates are protected

- Releases are built and signed on the maintainer's Mac; signing keys never leave it.
- Every update is signed with an EdDSA key. Stash checks that signature against the public key
  built into the app and refuses any update that doesn't match.
- The app runs with the hardened runtime.
