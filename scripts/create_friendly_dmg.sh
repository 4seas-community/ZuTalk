#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <ZuTalk.app> <version> <output.dmg>" >&2
  exit 2
fi

APP_PATH="$1"
VERSION="$2"
OUTPUT_DMG="$3"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
BACKGROUND="$ROOT_DIR/packaging/dmg-background.png"
VOLUME_NAME="ZuTalk $VERSION"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/zutalk-dmg.XXXXXX")"
STAGING_DIR="$WORK_DIR/staging"
MOUNT_DIR="$WORK_DIR/mount"
VERIFY_MOUNT_DIR="$WORK_DIR/verify"
WRITABLE_DMG="$WORK_DIR/ZuTalk-writable.dmg"
DEVICE=""
VERIFY_DEVICE=""

# Never forced. A volume that will not let go is in use, and the use that
# matters is Finder copying ZuTalk.app out of it: tearing the volume away
# mid-copy is what left /Applications/ZuTalk.app missing or an empty shell
# after four releases. Waiting lets that copy finish; a volume still busy
# after a minute fails this step, before anything is tagged or published.
detach_image() {
  local device="$1"
  local attempt
  for attempt in $(seq 1 60); do
    if hdiutil detach "$device" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo "FAIL: $device is still in use after 60 s; not forcing it" >&2
  return 1
}

cleanup() {
  if [[ -n "$VERIFY_DEVICE" ]]; then
    hdiutil detach "$VERIFY_DEVICE" -force >/dev/null 2>&1 || true
  fi
  if [[ -n "$DEVICE" ]]; then
    hdiutil detach "$DEVICE" -force >/dev/null 2>&1 || true
  fi
  if mount | grep -Fq " on $MOUNT_DIR "; then
    hdiutil detach "$MOUNT_DIR" -force >/dev/null 2>&1 || true
  fi
  case "$WORK_DIR" in
    "${TMPDIR:-/tmp}"/zutalk-dmg.*)
      find "$WORK_DIR" -depth -delete 2>/dev/null || true
      ;;
  esac
}
trap cleanup EXIT

[[ -d "$APP_PATH" ]] || {
  echo "FAIL: app bundle not found: $APP_PATH" >&2
  exit 1
}
[[ -f "$BACKGROUND" ]] || {
  echo "FAIL: DMG background not found: $BACKGROUND" >&2
  exit 1
}
[[ "$VERSION" =~ ^[0-9]+([.][0-9]+){2}([-+][0-9A-Za-z.-]+)?$ ]] || {
  echo "FAIL: invalid version: $VERSION" >&2
  exit 1
}
[[ ! -e "/Volumes/$VOLUME_NAME" ]] || {
  echo "FAIL: /Volumes/$VOLUME_NAME is already mounted; eject it before packaging" >&2
  exit 1
}

mkdir -p "$STAGING_DIR/.background"
ditto "$APP_PATH" "$STAGING_DIR/ZuTalk.app"
# Finder has to open the volume to record its layout, and while it does the
# window on screen is a working installer: dragging ZuTalk.app onto a real
# Applications shortcut there replaced the installed app from a volume this
# script was about to unmount. During layout the slot holds an empty folder
# of the same name — Finder keys icon positions by name — and the shortcut
# (ln -s /Applications) takes its place only after the window has closed.
mkdir "$STAGING_DIR/Applications"
ditto "$BACKGROUND" "$STAGING_DIR/.background/background.png"

hdiutil create \
  -volname "$VOLUME_NAME" \
  -fs HFS+ \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDRW \
  "$WRITABLE_DMG" >/dev/null

ATTACH_OUTPUT="$(
  hdiutil attach "$WRITABLE_DMG" -readwrite -noverify -noautoopen
)"
DEVICE="$(
  awk 'index($1, "/dev/disk") == 1 && NF >= 3 { device=$1 } END { print device }' \
    <<<"$ATTACH_OUTPUT"
)"
MOUNT_DIR="$(
  awk '
    index($1, "/dev/disk") == 1 && NF >= 3 {
      $1=$2=""
      sub(/^[[:space:]]+/, "")
      mount=$0
    }
    END { print mount }
  ' <<<"$ATTACH_OUTPUT"
)"
[[ -n "$DEVICE" && -d "$MOUNT_DIR" ]] || {
  echo "FAIL: unable to mount writable DMG" >&2
  exit 1
}

chflags hidden "$MOUNT_DIR/.background"

osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$VOLUME_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {100, 100, 820, 540}
    set theView to icon view options of container window
    set arrangement of theView to not arranged
    set icon size of theView to 112
    set text size of theView to 14
    set background picture of theView to file ".background:background.png"
    set position of item "ZuTalk.app" of container window to {200, 225}
    set position of item "Applications" of container window to {520, 225}
    update without registering applications
    delay 2
    close
  end tell
end tell
APPLESCRIPT

# The layout is written; now the real shortcut. An Applications folder that
# is no longer empty means something was dropped on it while the window was
# open — stop rather than ship it.
rmdir "$MOUNT_DIR/Applications" || {
  echo "FAIL: something was dropped into the DMG while Finder laid it out; rebuild" >&2
  exit 1
}
ln -s /Applications "$MOUNT_DIR/Applications"

sync
detach_image "$DEVICE"
DEVICE=""

mkdir -p "$(dirname "$OUTPUT_DMG")"
rm -f -- "$OUTPUT_DMG"
hdiutil convert "$WRITABLE_DMG" \
  -format ULMO \
  -o "$OUTPUT_DMG" >/dev/null

VERIFY_ATTACH_OUTPUT="$(
  hdiutil attach "$OUTPUT_DMG" -readonly -noverify -noautoopen -nobrowse
)"
VERIFY_DEVICE="$(
  awk 'index($1, "/dev/disk") == 1 && NF >= 3 { device=$1 } END { print device }' \
    <<<"$VERIFY_ATTACH_OUTPUT"
)"
VERIFY_MOUNT_DIR="$(
  awk '
    index($1, "/dev/disk") == 1 && NF >= 3 {
      $1=$2=""
      sub(/^[[:space:]]+/, "")
      mount=$0
    }
    END { print mount }
  ' <<<"$VERIFY_ATTACH_OUTPUT"
)"
[[ -n "$VERIFY_DEVICE" && -d "$VERIFY_MOUNT_DIR" ]] || {
  echo "FAIL: unable to mount finished DMG" >&2
  exit 1
}
[[ -d "$VERIFY_MOUNT_DIR/ZuTalk.app" ]] || {
  echo "FAIL: finished DMG is missing ZuTalk.app" >&2
  exit 1
}
[[ -L "$VERIFY_MOUNT_DIR/Applications" ]] || {
  echo "FAIL: finished DMG is missing the Applications shortcut" >&2
  exit 1
}
[[ "$(readlink "$VERIFY_MOUNT_DIR/Applications")" == "/Applications" ]] || {
  echo "FAIL: Applications shortcut has an unexpected target" >&2
  exit 1
}
[[ -f "$VERIFY_MOUNT_DIR/.background/background.png" ]] || {
  echo "FAIL: finished DMG is missing its background" >&2
  exit 1
}
[[ -f "$VERIFY_MOUNT_DIR/.DS_Store" ]] || {
  echo "FAIL: finished DMG is missing Finder layout metadata" >&2
  exit 1
}

detach_image "$VERIFY_DEVICE"
VERIFY_DEVICE=""

SIZE="$(du -h "$OUTPUT_DMG" | awk '{print $1}')"
echo "✓ Friendly DMG created: $OUTPUT_DMG ($SIZE)"
