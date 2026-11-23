#!/bin/bash
# Renders macos/Resources/AppIcon.svg into macos/Resources/AppIcon.icns.
# Run it from the devshell (it provides resvg) after changing the SVG, and commit both files.
set -euo pipefail

resources="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../Resources" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

iconset="$work/AppIcon.iconset"
mkdir -- "$iconset"
for size in 16 32 128 256 512; do
  resvg -w "$size" -h "$size" "$resources/AppIcon.svg" "$iconset/icon_${size}x${size}.png"
  resvg -w $((size * 2)) -h $((size * 2)) "$resources/AppIcon.svg" "$iconset/icon_${size}x${size}@2x.png"
done
iconutil -c icns -o "$resources/AppIcon.icns" "$iconset"
