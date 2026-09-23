#!/bin/bash
set -euo pipefail
within_root="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="$within_root/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$within_root/.build/module-cache"
cd "$within_root"
./scripts/prepare-fluidaudio.sh
swift build --disable-sandbox --manifest-cache local -c release -debug-info-format none
binary_dir="$(swift build --disable-sandbox --manifest-cache local -c release -debug-info-format none --show-bin-path)"
bundle="$within_root/build/Within.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$binary_dir/Within" "$bundle/Contents/MacOS/Within"
cp Info.plist "$bundle/Contents/Info.plist"
mkdir -p "$within_root/.development"
swift scripts/make-icon.swift "$within_root/.development/Within.iconset"
iconutil -c icns "$within_root/.development/Within.iconset" -o "$bundle/Contents/Resources/Within.icns"
for resource in "$binary_dir"/*.bundle; do
    test -d "$resource" || continue
    destination="$bundle/Contents/Resources/$(basename "$resource")"
    if [ -d "$destination" ]; then rm -rf "$destination"; fi
    cp -R "$resource" "$destination"
done
for notice in LICENSE THIRD_PARTY_NOTICES.md; do
    if [ -f "$notice" ]; then cp "$notice" "$bundle/Contents/Resources/"; fi
done
mkdir -p "$bundle/Contents/Resources/ThirdPartyLicenses"
cp Vendor/FluidAudio/LICENSE "$bundle/Contents/Resources/ThirdPartyLicenses/FluidAudio-APACHE-2.0.txt"
cp Vendor/FluidAudio/ThirdPartyLicenses/* "$bundle/Contents/Resources/ThirdPartyLicenses/"
codesign --force --sign "${WITHIN_SIGNING_IDENTITY:--}" --options runtime --entitlements Entitlements.plist "$bundle"
codesign --verify --strict "$bundle"
printf '%s\n' "$bundle"
