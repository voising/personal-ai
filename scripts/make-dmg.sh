#!/usr/bin/env bash
# Packs build/Personal AI.app into build/PersonalAI.dmg with a styled Finder window:
# background art, large icons at fixed positions, no toolbar, and the app icon as the volume icon.
# Usage: scripts/make-dmg.sh   (run after build-app.sh; build-app.sh calls it when NOTARIZE=1)
# Finder lays out the window through AppleScript, so the first run asks to allow
# the terminal to control Finder.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Personal AI.app"
DMG="build/PersonalAI.dmg"     # fixed name: the website links to releases/latest/download/PersonalAI.dmg
VOL="Personal AI"
STAGE="build/dmg"
RW="build/PersonalAI-rw.dmg"

rm -rf "$STAGE" "$DMG" "$RW"
mkdir -p "$STAGE/.background"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp Resources/dmg-background.tiff "$STAGE/.background/background.tiff"
cp build/icon/AppIcon.icns "$STAGE/.VolumeIcon.icns"

# Eject every other "Personal AI" volume (an older DMG left open), or Finder saves the
# layout to the wrong disk.
for V in "/Volumes/$VOL"*; do [ -d "$V" ] && hdiutil detach -quiet -force "$V" || true; done

hdiutil create -quiet -volname "$VOL" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$RW"
DEV=$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | awk '/Apple_HFS/ {print $1}')
SetFile -a C "/Volumes/$VOL"
chflags hidden "/Volumes/$VOL/.background" "/Volumes/$VOL/.VolumeIcon.icns"

# Window content is 660 x 400 pt, matching Resources/dmg-background.png. Finder draws an icon
# about 44 pt below its position, so {x, 146} puts the icon centre on the arrow at y = 190.
osascript <<OSA
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set pathbar visible of container window to false
    set sidebar width of container window to 0
    set the bounds of container window to {200, 120, 860, 548}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set text size of opts to 13
    set label position of opts to bottom
    set shows item info of opts to false
    set background picture of opts to file ".background:background.tiff"
    set position of item "Personal AI.app" of container window to {170, 146}
    set position of item "Applications" of container window to {490, 146}
    -- Out of sight for people who show hidden files.
    set position of item ".background" of container window to {170, 700}
    set position of item ".VolumeIcon.icns" of container window to {490, 700}
    update without registering applications
    delay 1
    close
    open
    delay 2
    close
  end tell
end tell
OSA

sync
rm -rf "/Volumes/$VOL/.fseventsd"
hdiutil detach -quiet "$DEV"
hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG"
rm -f "$RW"
echo "Built $DMG ($(du -h "$DMG" | cut -f1))"
