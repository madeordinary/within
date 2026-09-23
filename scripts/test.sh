#!/bin/bash
set -euo pipefail
within_root="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="$within_root/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$within_root/.build/module-cache"
cd "$within_root"
./scripts/prepare-fluidaudio.sh
swift test --disable-sandbox --manifest-cache local
mkdir -p .development
xcrun clang -std=c11 -O1 -g -fsanitize=thread -I Sources/WithinAudioBuffer/include Tests/AudioBufferStress/main.c Sources/WithinAudioBuffer/WithinAudioBuffer.c -o .development/audio-ring-stress
.development/audio-ring-stress
