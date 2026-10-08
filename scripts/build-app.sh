#!/usr/bin/env bash
# Builds build/Personal AI.app with Ollama bundled inside.
#   OLLAMA_VERSION  Ollama release to bundle (default below)
#   SIGN_IDENTITY   "Developer ID Application: …" for distribution; ad-hoc ("-") otherwise
#   NOTARIZE=1      also notarize + staple and build build/PersonalAI.dmg
#                   (uses ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH)
set -euo pipefail
cd "$(dirname "$0")/.."

OLLAMA_VERSION="${OLLAMA_VERSION:-v0.40.0}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed s/^v// || true)}"; VERSION="${VERSION:-0.1.0}"
REPO="voising/personal-ai"
TS="--timestamp"; [ "$SIGN_IDENTITY" = "-" ] && TS="--timestamp=none"
APP="build/Personal AI.app"
VENDOR="vendor/ollama-$OLLAMA_VERSION"

if [ ! -x "$VENDOR/ollama" ]; then
  echo "Fetching Ollama $OLLAMA_VERSION"
  mkdir -p "$VENDOR"
  curl -fL --progress-bar "https://github.com/ollama/ollama/releases/download/$OLLAMA_VERSION/ollama-darwin.tgz" \
    | tar xz -C "$VENDOR"
fi

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/PersonalAI"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/ollama"
cp "$BIN" "$APP/Contents/MacOS/PersonalAI"
cp Resources/models.json "$APP/Contents/Resources/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp -R "$VENDOR/." "$APP/Contents/Resources/ollama/"

# Apple silicon only: drop Intel-only libraries and thin universal binaries to arm64.
find "$APP/Contents/Resources/ollama" -type f \( -perm -u+x -o -name '*.dylib' -o -name '*.so' \) -print0 |
while IFS= read -r -d '' F; do
  case "$(lipo -archs "$F" 2>/dev/null)" in
    x86_64) rm "$F" ;;
    *x86_64*arm64*|*arm64*x86_64*) lipo -thin arm64 "$F" -output "$F.arm64" && mv "$F.arm64" "$F" ;;
  esac
done
find "$APP/Contents/Resources/ollama" -type l ! -exec test -e {} \; -delete   # symlinks to removed Intel libs

# The MLX engine (~200 MB per Metal version) is not shipped in the app. Each build becomes a
# release asset that the app downloads only when its model needs MLX (see MLXRuntime.swift).
rm -rf build/mlx && mkdir -p build/mlx
MANIFEST="{\"ollama\": \"$OLLAMA_VERSION\", \"variants\": {"
SEP=""
for V in mlx_metal_v3 mlx_metal_v4; do
  mv "$APP/Contents/Resources/ollama/$V" "build/mlx/$V"
  find "build/mlx/$V" -type f \( -name '*.dylib' -o -perm -u+x \) -print0 \
    | xargs -0 codesign --force --options runtime $TS --sign "$SIGN_IDENTITY"
  (cd build/mlx && ditto -c -k --keepParent "$V" "$V.zip")
  SHA=$(shasum -a 256 "build/mlx/$V.zip" | cut -d' ' -f1)
  MANIFEST="$MANIFEST$SEP\"$V\": {\"url\": \"https://github.com/$REPO/releases/download/v$VERSION/$V.zip\", \"sha256\": \"$SHA\"}"
  SEP=", "
done
echo "$MANIFEST}}" > "$APP/Contents/Resources/mlx.json"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.railssquad.personalai</string>
  <key>CFBundleName</key><string>Personal AI</string>
  <key>CFBundleDisplayName</key><string>Personal AI</string>
  <key>CFBundleExecutable</key><string>PersonalAI</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSArchitecturePriority</key><array><string>arm64</string></array>
  <key>LSRequiresNativeExecution</key><true/>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>Open source. Ollama is MIT licensed.</string>
</dict></plist>
PLIST

# Sign inside-out: every bundled binary and dylib, then the app (hardened runtime for notarization).
find "$APP/Contents/Resources/ollama" -type f \( -perm -u+x -o -name '*.dylib' -o -name '*.so' \) -print0 \
  | xargs -0 codesign --force --options runtime $TS --sign "$SIGN_IDENTITY"
codesign --force --options runtime $TS --sign "$SIGN_IDENTITY" "$APP"

echo "Built $APP ($(du -sh "$APP" | cut -f1))"

if [ "${NOTARIZE:-0}" = 1 ]; then
  DMG="build/PersonalAI.dmg"   # fixed name: the website links to releases/latest/download/PersonalAI.dmg
  rm -rf build/dmg "$DMG"; mkdir -p build/dmg
  cp -R "$APP" build/dmg/; ln -s /Applications build/dmg/Applications
  hdiutil create -volname "Personal AI" -srcfolder build/dmg -ov -format UDZO "$DMG" >/dev/null
  codesign --force $TS --sign "$SIGN_IDENTITY" "$DMG"
  xcrun notarytool submit "$DMG" --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" --wait
  xcrun stapler staple "$DMG"
  spctl -a -t open --context context:primary-signature -v "$DMG"
  shasum -a 256 "$DMG"
  echo "Release assets: $DMG build/mlx/mlx_metal_v3.zip build/mlx/mlx_metal_v4.zip"
fi
