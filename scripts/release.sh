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
./scripts/test.sh
./scripts/build.sh
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
2. Drag Within into the Applications folder (replace the old copy).
3. Open Within. If macOS says it can't verify the app, click Done, then open
   System Settings > Privacy & Security and click "Open Anyway".
4. Allow Microphone and Accessibility if asked. An unsigned update may ask for
   Accessibility again.

Your settings, history and notes are kept in ~/Library/Application Support/Within
and stay when you replace the app. Audio is never saved.

Check for updates any time from the Within menu. Updates never install themselves.
README
dmg="$out/Within-${version}-build${build}.dmg"
hdiutil create -quiet -volname "Within" -srcfolder "$stage" -ov -format UDZO "$dmg"
hdiutil verify -quiet "$dmg"
mount="$(hdiutil attach -nobrowse -readonly "$dmg" | tail -1 | awk -F'\t' '{print $NF}')"
diff -rq build/Within.app "$mount/Within.app"
codesign --verify --strict "$mount/Within.app"
hdiutil detach -quiet "$mount"
(cd "$out" && shasum -a 256 "$(basename "$dmg")" > SHA256SUMS)
previous="$(git describe --tags --abbrev=0 2>/dev/null || true)"
{
  echo "Within ${version} (build ${build}), engineering preview."
  echo
  echo "Not signed with a Developer ID yet: see Read Me First in the DMG for Open Anyway."
  echo "Requires Apple silicon and macOS 14 or later. Validation gates in docs/VALIDATION.md remain open."
  echo
  echo "Changes:"
  if [ -n "$previous" ]; then git log --format='- %s' "${previous}..HEAD"; else git log --format='- %s' -15; fi
} > "$out/release-notes.md"
echo "Release candidate ready in $out (not published)."
echo "Review release-notes.md, then publish only when approved:"
echo "  gh release create ${tag} --target $(git rev-parse HEAD) --prerelease --title \"Within ${version} (build ${build})\" --notes-file ${out}/release-notes.md ${dmg} ${out}/SHA256SUMS"
