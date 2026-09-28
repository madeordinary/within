#!/bin/bash
# Makes the install DMG from a stage folder (Within.app, an Applications link, Read Me First.txt):
# a window with the real icons over a background showing where to drag and how to open Within.
# Finder saves the layout, so this needs a logged-in session, and macOS asks once per host app
# for permission to control Finder. Building the image happens only here, so replacing hdiutil
# with `diskutil image` later starts in this file (release.sh only verifies the result).
set -euo pipefail
usage="usage: make-dmg.sh <stage folder> <volume name> <output.dmg>"
stage="${1:?$usage}"; volume="${2:?$usage}"; output="${3:?$usage}"
within_root="$(cd "$(dirname "$0")/.." && pwd)"
if [ -e "/Volumes/$volume" ]; then echo "Eject the disk named \"$volume\" first; Finder would confuse the two."; exit 1; fi
# Finder's layout records where this image was built, so build it under a neutral name, not a
# per-user temporary folder.
work="$(mktemp -d /tmp/within-dmg.XXXXXX)"
mountpoint=""
cleanup() {
    if [ -n "$mountpoint" ] && [ -d "$mountpoint" ]; then hdiutil detach -quiet "$mountpoint" 2>/dev/null || hdiutil detach -quiet -force "$mountpoint" 2>/dev/null || true; fi
    rm -rf "$work"
}
trap cleanup EXIT

mkdir -p "$stage/.background"
swift "$within_root/scripts/make-dmg-background.swift" "$work"
tiffutil -cathidpicheck "$work/background.png" "$work/background@2x.png" -out "$stage/.background/background.tiff" >/dev/null

# A writable image with room for Finder's layout file, converted to a compressed one at the end.
size_mb=$(( $(du -sm "$stage" | cut -f1) + 20 ))
hdiutil create -quiet -volname "$volume" -srcfolder "$stage" -fs APFS -format UDRW -size "${size_mb}m" "$work/layout.dmg"
mountpoint="$(hdiutil attach -readwrite -noverify -noautoopen "$work/layout.dmg" | awk -F'\t' '/\/Volumes\// { print $NF }' | tail -1)"
if [ "$mountpoint" != "/Volumes/$volume" ]; then echo "The image mounted at \"$mountpoint\", not /Volumes/$volume."; exit 1; fi

# Positions are icon centers in points, matching make-dmg-background.swift.
if ! osascript - "$volume" <<'APPLESCRIPT'
on run argv
    set volumeName to item 1 of argv
    tell application "Finder"
        tell disk volumeName
            open
            set theWindow to container window
            set current view of theWindow to icon view
            set toolbar visible of theWindow to false
            set statusbar visible of theWindow to false
            set bounds of theWindow to {200, 120, 860, 600}
            set theOptions to icon view options of theWindow
            set arrangement of theOptions to not arranged
            set icon size of theOptions to 96
            set text size of theOptions to 13
            set label position of theOptions to bottom
            set shows item info of theOptions to false
            set shows icon preview of theOptions to false
            set background picture of theOptions to file ".background:background.tiff"
            set position of item "Within.app" of theWindow to {170, 175}
            set position of item "Applications" of theWindow to {490, 175}
            set position of item "Read Me First.txt" of theWindow to {560, 350}
            close
            open
            update without registering applications
            delay 1
            close
        end tell
    end tell
end run
APPLESCRIPT
then
    echo "Finder couldn't lay out the window. If macOS asked to let this app control Finder, allow it in System Settings > Privacy & Security > Automation and try again."
    exit 1
fi

# Finder writes .DS_Store on its own schedule. Wait until it holds the background and every
# icon position, and fail rather than ship a plain window. It must not contain local paths.
python3 - "$mountpoint/.DS_Store" <<'PYTHON'
import sys, time
from pathlib import Path
path = Path(sys.argv[1])
names = ["Within.app", "Applications", "Read Me First.txt"]
def complete(data):
    return b"icvp" in data and b"pBBk" in data and all(name.encode("utf-16-be") + b"Iloc" in data for name in names)
for _ in range(30):
    data = path.read_bytes() if path.exists() else b""
    if complete(data): break
    time.sleep(1)
else:
    sys.exit("Finder didn't save the window layout (background and icon positions).")
for text in ("/Users/", "/home/", "/var/folders/"):
    for encoding in ("utf-8", "utf-16-be", "utf-16-le"):
        if text.encode(encoding) in data: sys.exit("The window layout contains a local path.")
PYTHON

sync
for attempt in 1 2 3 4 5; do
    if hdiutil detach -quiet "$mountpoint"; then mountpoint=""; break; fi
    [ "$attempt" = 5 ] && { echo "Couldn't eject the layout image."; exit 1; }
    sleep 2
done
hdiutil convert -quiet "$work/layout.dmg" -format UDZO -imagekey zlib-level=9 -ov -o "$output"
