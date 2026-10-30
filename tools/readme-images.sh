#!/bin/bash
# Draws the README images into .github/assets, from synthetic data only:
#   icon.png              the app icon of the last `make build` (tools/render-icon.swift), 1024 px
#   hero-light.png, hero-dark.png, panel.png, transforms.png, jobs.png, social-preview.png
#                         the YabUITests/ReadmeSnapshot suite, already at their final sizes
# Usage: tools/readme-images.sh   (builds the app first when there is no build; never launches it)
set -euo pipefail
cd "$(dirname "$0")/.."

APP=DerivedData/Build/Products/Debug/yabbistir.app
OUT=.github/assets
NAMES=(icon hero-light hero-dark panel transforms jobs social-preview)

[ -d "$APP" ] || make build

work=$(mktemp -d "${TMPDIR:-/tmp}/yab-readme.XXXXXX")
trap 'rm -rf "$work"' EXIT

swift tools/render-icon.swift "$APP" "$work/icon.png" 1024 > /dev/null
# The suite reads icon.png from the same folder for the social preview.
if ! TEST_RUNNER_YAB_SNAPSHOT_DIR="$work" make test ONLY=YabUITests/ReadmeSnapshot > "$work/test.log" 2>&1; then
    cat "$work/test.log"
    echo "readme-images: the snapshot suite failed" >&2
    exit 1
fi
for name in "${NAMES[@]}"; do
    if [ ! -s "$work/$name.png" ]; then
        cat "$work/test.log"
        echo "readme-images: $name.png was not drawn" >&2
        exit 1
    fi
done

mkdir -p "$OUT"
for name in "${NAMES[@]}"; do
    cp "$work/$name.png" "$OUT/$name.png"
    size=$(sips -g pixelWidth -g pixelHeight "$OUT/$name.png" | awk '/pixelWidth/ { w = $2 } /pixelHeight/ { h = $2 } END { print w "×" h }')
    echo "$OUT/$name.png: $size, $(( $(stat -f %z "$OUT/$name.png") / 1024 )) KB"
done
