#!/bin/zsh
# Builds Linker.app (release) into ./build. Usage: scripts/bundle.sh
# BUNDLE_ID sets the app's identifier (use a reverse-DNS name you own for builds you distribute).
set -euo pipefail
cd "${0:A:h}/.."
BUNDLE_ID="${BUNDLE_ID:-io.github.chrija76.linker}"
VERSION="${VERSION:-1.1}"
swift build -c release --product Linker
# Assemble and sign outside the project: synced folders (iCloud Desktop/Documents) add Finder attributes that codesign rejects.
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
APP="$WORK/Linker.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Linker "$APP/Contents/MacOS/Linker"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>Linker</string>
  <key>CFBundleDisplayName</key><string>Linker</string>
  <key>CFBundleExecutable</key><string>Linker</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
# Sign with the stable self-signed identity when present, so macOS keeps Linker's Accessibility permission
# across rebuilds (an ad-hoc signature changes with every build). Create it once with scripts/make-cert.sh.
IDENTITY=$(security find-identity -p codesigning | awk -F'"' '/Linker Self-Signed/ {print $2; exit}')
xattr -cr "$APP"
codesign --force --sign "${IDENTITY:--}" --identifier "$BUNDLE_ID" "$APP"
[[ -n "$IDENTITY" ]] || echo "warning: signed ad hoc; Accessibility will need re-granting after each build"
mkdir -p build && rm -rf build/Linker.app && ditto "$APP" build/Linker.app
echo "Built $PWD/build/Linker.app"
