#!/bin/zsh
# Build "Preroll.app" - a menu bar app (no Dock icon) with the command line
# tools inside it, so that one bundle is the whole thing to ship.
#
#   ./build-app.sh [version]
#
# Universal by default: Homebrew serves the same download to every Mac, and a
# binary built for this machine alone would not run on the other architecture.
# Set PREROLL_ARCHS="arm64" to build only for this one while developing.
#
# Signing: ad-hoc unless CODESIGN_ID is set, which is what release builds do
# (see .github/workflows/release.yml). An ad-hoc signed app is fine to run
# locally but Gatekeeper refuses it once it has been downloaded.
set -e
cd "$(dirname "$0")"

APP="Preroll.app"
VERSION=${1:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')}
VERSION=${VERSION:-0.0.0}
ARCHS=${PREROLL_ARCHS:-"arm64 x86_64"}
# Matches LSMinimumSystemVersion below. Without an explicit target, swiftc
# builds against the SDK's own version and the app refuses to launch on older
# systems.
DEPLOY=13.0

rm -rf "$APP" build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Preroll</string>
  <key>CFBundleDisplayName</key><string>Preroll</string>
  <key>CFBundleIdentifier</key><string>com.ksha23.preroll</string>
  <key>CFBundleExecutable</key><string>AirPlayLatency</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>$DEPLOY</string>
  <key>LSUIElement</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# $1 source, $2 output path
build_universal() {
  local src=$1 out=$2 slices=()
  for arch in ${=ARCHS}; do
    swiftc -O -target "$arch-apple-macos$DEPLOY" "$src" -o "build/$(basename "$out").$arch"
    slices+=("build/$(basename "$out").$arch")
  done
  if [ ${#slices[@]} -gt 1 ]; then
    lipo -create "${slices[@]}" -output "$out"
  else
    cp "${slices[1]}" "$out"
  fi
}

printf 'building %-22s <- src/MenuBarApp.swift\n' "AirPlayLatency"
build_universal src/MenuBarApp.swift "$APP/Contents/MacOS/AirPlayLatency"

# The measurement tools ride along inside the bundle; the cask symlinks them
# onto the PATH from there.
for t in adump:preroll-latency aplat:aplat apstart:apstart keepalive:preroll-keepalive; do
  SRC="${t%%:*}"; OUT="${t##*:}"
  printf 'building %-22s <- src/%s.swift\n' "$OUT" "$SRC"
  build_universal "src/$SRC.swift" "$APP/Contents/MacOS/$OUT"
done

rm -rf build

if [ -n "$CODESIGN_ID" ]; then
  # Hardened runtime and a timestamp are what notarization requires
  codesign --force --options runtime --timestamp --sign "$CODESIGN_ID" \
    "$APP/Contents/MacOS/"* "$APP"
  echo "signed with $CODESIGN_ID"
else
  codesign --force --deep --sign - "$APP" 2>/dev/null || true
  echo "ad-hoc signed (set CODESIGN_ID for a release build)"
fi

echo "built: $PWD/$APP  version $VERSION  ($(lipo -archs "$APP/Contents/MacOS/AirPlayLatency"))"
echo "run it with:  open \"$APP\""
echo "install with: cp -R \"$APP\" /Applications/"
