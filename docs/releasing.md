# Releasing

## Before the first public push

- Publish from a fresh repository with one initial commit, not this repo's history.
- Search the tree for names, emails, internal URLs and real link data:
  `grep -rniE "<your company>|<your name>|@<your domain>" --exclude-dir=.build .`
- Choose the bundle identifier (a reverse-DNS name you own) and set it in `scripts/bundle.sh` (`BUNDLE_ID`).
- Add a `LICENSE` file.

## Source releases (no Apple account needed)

Users build with `scripts/make-cert.sh` and `scripts/bundle.sh` (see the README). A locally built app isn't quarantined, so Gatekeeper doesn't block it. The self-signed identity keeps the Accessibility permission across rebuilds.

## Binary releases (Developer ID)

Requires a paid Apple Developer account.

1. Build: `BUNDLE_ID=<id> VERSION=<x.y> scripts/bundle.sh`
2. Sign with the hardened runtime:
   `codesign --force --options runtime --timestamp --sign "Developer ID Application: <Name> (<TEAMID>)" build/Linker.app`
3. Zip and notarize:
   `ditto -c -k --keepParent build/Linker.app Linker.zip`
   `xcrun notarytool submit Linker.zip --keychain-profile <profile> --wait`
4. Staple and re-zip: `xcrun stapler staple build/Linker.app`, then zip again.
5. Attach the zip to a GitHub release. Optionally publish a Homebrew cask that points at it.

Users of a signed build still grant Accessibility once. Updates signed with the same Developer ID keep that permission.
