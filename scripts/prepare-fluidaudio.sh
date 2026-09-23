#!/bin/bash
set -euo pipefail
within_root="$(cd "$(dirname "$0")/.." && pwd)"
revision="b811a61569aa02691c99b808d08ee989b630c133"
destination="$within_root/Vendor/FluidAudio"
patch_file="$within_root/Patches/fluidaudio-privacy-and-bounded-ingress.patch"
if [ -f "$destination/.within-revision" ]; then
    test "$(cat "$destination/.within-revision")" = "$revision"
    # Refuse a dependency whose expected patch has been removed or drifted.
    (cd "$destination" && patch --dry-run --silent -R -p1 < "$patch_file")
    exit 0
fi
if [ -e "$destination" ]; then
    printf '%s\n' 'Incomplete Vendor/FluidAudio directory. Move it aside before preparing again.' >&2
    exit 1
fi
mkdir -p "$within_root/Vendor"
scratch="$(mktemp -d "$within_root/Vendor/prepare.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
git clone --no-checkout --filter=blob:none https://github.com/FluidInference/FluidAudio.git "$scratch/source"
git -C "$scratch/source" checkout --detach "$revision"
test "$(git -C "$scratch/source" rev-parse HEAD)" = "$revision"
mkdir "$scratch/export"
git -C "$scratch/source" archive "$revision" | tar -xf - -C "$scratch/export"
(cd "$scratch/export" && patch --batch -p1 < "$patch_file")
printf '%s\n' "$revision" > "$scratch/export/.within-revision"
mv "$scratch/export" "$destination"
