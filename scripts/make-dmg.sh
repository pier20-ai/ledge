#!/usr/bin/env bash
# Wrap a built (ideally notarized) Ledge.app in the release DMG: a night-sky
# Finder window where the Applications alias sits inside a drawn menu-bar
# notch, and the app icon waits on a mossy ledge below. You install Ledge by
# dragging it into the notch — the same gesture the app itself is.
#
# Usage: scripts/make-dmg.sh [path/to/Ledge.app] [--identity <name>] [--notarize]
#
# Assets come from scripts/assets/dmg (background.tiff is 1x+2x, composed by
# compose-dmg-background.py from mj-artwork/dmg). Layout is applied by Finder
# scripting on a read-write image, then compressed to UDZO and signed.
# --notarize additionally submits the DMG under the "ledge-notary" profile and
# staples the ticket (the .app inside should already be notarized).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASSETS="$REPO_ROOT/scripts/assets/dmg"

APP="$REPO_ROOT/dist/Ledge.app"
IDENTITY="${LEDGE_SIGN_IDENTITY:-}"
NOTARIZE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --identity) IDENTITY="$2"; shift 2 ;;
    --notarize) NOTARIZE=1; shift ;;
    *) APP="$1"; shift ;;
  esac
done

log()  { printf '\033[1;34m[dmg]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[dmg] FAIL:\033[0m %s\n' "$*" >&2; exit 1; }

[ -d "$APP" ] || fail "no app at $APP (run bundle-app.sh first)"
[ -f "$ASSETS/background.tiff" ] || fail "no background.tiff in $ASSETS"
[ -f "$ASSETS/VolumeIcon.icns" ] || fail "no VolumeIcon.icns in $ASSETS"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' \
  "$APP/Contents/Info.plist" 2>/dev/null || echo dev)"
VOLNAME="Ledge"
DMG="$REPO_ROOT/dist/Ledge-$VERSION.dmg"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/ledge-dmg.XXXXXX")"
RW="$STAGE/rw.dmg"
MOUNT=""
trap '[ -n "$MOUNT" ] && hdiutil detach "$MOUNT" -quiet 2>/dev/null; rm -rf "$STAGE"' EXIT

# --- stage ------------------------------------------------------------------
# ${VERSION} braced: some locales let bash fold a following multibyte char
# (the ellipsis) into the variable name, and set -u makes that fatal.
log "staging $VOLNAME ${VERSION}…"
mkdir -p "$STAGE/root/.background"
cp -R "$APP" "$STAGE/root/Ledge.app"
ln -s /Applications "$STAGE/root/Applications"
cp "$ASSETS/background.tiff" "$STAGE/root/.background/background.tiff"
cp "$ASSETS/VolumeIcon.icns" "$STAGE/root/.VolumeIcon.icns"

hdiutil create -srcfolder "$STAGE/root" -volname "$VOLNAME" \
  -fs HFS+ -format UDRW -quiet "$RW" || fail "hdiutil create failed"

MOUNT="/Volumes/$VOLNAME"
hdiutil detach "$MOUNT" -quiet 2>/dev/null || true
hdiutil attach "$RW" -mountpoint "$MOUNT" -nobrowse -quiet \
  || fail "could not mount the rw image"
SetFile -a C "$MOUNT" 2>/dev/null || true  # honor .VolumeIcon.icns

# --- layout -----------------------------------------------------------------
# Window 600x400pt over the composed background; the Applications alias sits
# in the drawn notch, Ledge.app on the mossy ledge. Coordinates are icon
# centers in points.
log "arranging the Finder window…"
osascript <<EOF || fail "Finder layout failed (grant Automation permission?)"
tell application "Finder"
  tell disk "$VOLNAME"
    open
    set opts to the icon view options of container window
    tell container window
      set current view to icon view
      set toolbar visible to false
      set statusbar visible to false
      set the bounds to {200, 120, 800, 548}
    end tell
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set text size of opts to 12
    set background picture of opts to file ".background:background.tiff"
    set position of item "Ledge.app" of container window to {145, 235}
    set position of item "Applications" of container window to {300, 98}
    close
    open
    update without registering applications
    delay 1
    close
  end tell
end tell
EOF
sync

hdiutil detach "$MOUNT" -quiet || fail "could not detach the rw image"

# --- compress + sign --------------------------------------------------------
log "compressing…"
rm -f "$DMG"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -quiet -o "$DMG" \
  || fail "hdiutil convert failed"

if [ -n "$IDENTITY" ]; then
  log "signing the DMG…"
  codesign --force --sign "$IDENTITY" --timestamp "$DMG" \
    || fail "could not sign the DMG"
fi

if [ "$NOTARIZE" = 1 ]; then
  log "notarizing (this can take a few minutes)…"
  xcrun notarytool submit "$DMG" --keychain-profile ledge-notary --wait \
    || fail "notarization failed"
  xcrun stapler staple "$DMG" || fail "stapling failed"
fi

log "PASS — $DMG"
