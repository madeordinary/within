#!/bin/bash
# Builds a release candidate: tests, app bundle, native checks, DMG and checksums.
# It never uploads. Publishing is a separate, deliberate `gh release create` step.
set -euo pipefail
within_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$within_root"
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then echo "Commit tracked changes before building a release."; exit 1; fi
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)"
build="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' Info.plist)"
tag="v${version}-build${build}"
out="build/release/${tag}"
if [ -e "$out" ]; then echo "$out already exists; bump CFBundleVersion or remove it."; exit 1; fi
# Every release is signed with the same certificate so macOS permissions carry over between
# updates. scripts/signing-requirement.txt pins it; a different certificate fails the release.
identity="${WITHIN_SIGNING_IDENTITY:-$(security find-identity -p codesigning 2>/dev/null | awk '/"Within Signing"/ { print $2; exit }')}"
if [ -z "$identity" ] || [ "$identity" = "-" ]; then echo "Releases need the Within Signing certificate in your keychain; see docs/PUBLICATION.md."; exit 1; fi
git fetch --tags --quiet origin || echo "Could not fetch tags; the change list may be incomplete."
./scripts/test.sh
WITHIN_SIGNING_IDENTITY="$identity" ./scripts/build.sh
requirement() { codesign -d -r- "$1" 2>&1 | sed -n 's/^designated => //p'; }
if [ "$(requirement build/Within.app)" != "$(cat scripts/signing-requirement.txt)" ]; then
  echo "The app's signature doesn't match scripts/signing-requirement.txt. Users would have to allow permissions again."; exit 1
fi
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
bin="$(swift build --disable-sandbox --manifest-cache local -c release -debug-info-format none --show-bin-path)"
mkdir -p "$out"
"$bin/Within" --native-checks "$within_root/$out/native-checks.json"
if strings -a build/Within.app/Contents/MacOS/Within | grep -q "/Users/"; then echo "The app binary contains a local home path."; exit 1; fi
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
ditto build/Within.app "$stage/Within.app"
ln -s /Applications "$stage/Applications"
cat > "$stage/Read Me First.txt" <<README
Within ${version} (build ${build})

This is an engineering preview. Until it is signed with an Apple Developer ID,
macOS warns the first time you open it.

Requirements: a Mac with Apple silicon (M1 or later), macOS 14 or later.

Install or update
1. Quit Within if it is running.
2. Drag Within into the Applications folder, replacing the old copy. If your
   Within lives somewhere else, such as Applications in your home folder,
   replace that copy instead.
3. Open Within. The first time, macOS blocks it because Apple hasn't checked
   this test build. You get past it once:
   a. macOS says "Within" Not Opened. Click Done (not Move to Trash).
   b. Open System Settings > Privacy & Security and scroll down to Security.
   c. Next to the message that Within was blocked, click Open Anyway.
   d. Confirm with Open Anyway and your password or Touch ID.
4. Allow Microphone and Accessibility if asked.

From build 14 on, each build is signed with the same Made Ordinary certificate,
so updates keep the permissions you've allowed. Coming from build 13 or
earlier, macOS asks for Accessibility once more.

Your settings, history and notes are kept in ~/Library/Application Support/Within
and stay when you replace the app. Audio is never saved.

Check for updates any time from the Within menu. Updates never install themselves.
README
# One DMG per release, always named Within.dmg: .../releases/latest/download/Within.dmg then
# always fetches the newest build, and Within (build 16 on) downloads a release's only DMG.
dmg="$out/Within.dmg"
./scripts/make-dmg.sh "$stage" Within "$dmg"
hdiutil verify -quiet "$dmg"
mount="$(hdiutil attach -nobrowse -readonly "$dmg" | tail -1 | awk -F'\t' '{print $NF}')"
diff -rq build/Within.app "$mount/Within.app"
codesign --verify --strict "$mount/Within.app"
test "$(requirement "$mount/Within.app")" = "$(cat scripts/signing-requirement.txt)"
test -s "$mount/.DS_Store" && test -s "$mount/.background/background.tiff"
hdiutil detach -quiet "$mount"
(cd "$out" && shasum -a 256 "$(basename "$dmg")" > SHA256SUMS)
previous="$(git describe --tags --abbrev=0 2>/dev/null || true)"
# The app shows these notes in Settings > About, so they are for people, not developers:
# plain words about what changed for them. changes.txt lists the commits as a starting point.
if [ -n "$previous" ]; then git log --format='- %s' "${previous}..HEAD"; else git log --format='- %s' -15; fi > "$out/changes.txt"
{
  echo "What's new: REPLACE with the changes people will notice, in plain words."
  echo
  echo "To update: quit Within, drag the new Within into Applications, then open it. Your settings, history and notes stay."
  echo
  echo "First time installing? Steps: https://github.com/madeordinary/within#download"
} > "$out/release-notes.md"
echo "Release candidate ready in $out (not published)."
echo "Write What's new in release-notes.md (changes.txt lists the commits), then publish only when approved:"
echo "  gh release create ${tag} --target $(git rev-parse HEAD) --latest --title \"Within ${version} (build ${build})\" --notes-file ${out}/release-notes.md ${dmg} ${out}/SHA256SUMS"
