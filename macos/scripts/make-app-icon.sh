#!/bin/bash
# Renders macos/Resources/AppIcon.svg with and without the Preview badge.
# Run it from the devshell (it provides resvg) after changing the SVG, and commit both files.
set -euo pipefail

resources="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../Resources" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

for icon in AppIcon AppIconPreview; do
  svg="$resources/AppIcon.svg"
  if [[ "$icon" == AppIconPreview ]]; then
    svg="$work/$icon.svg"
    sed 's|</svg>|<circle cx="794" cy="794" r="170" fill="#ECA63B" stroke="#21192A" stroke-width="46"/><path d="M740 892V698H804C899 698 899 820 804 820H740" fill="none" stroke="#21192A" stroke-width="40"/></svg>|' \
      "$resources/AppIcon.svg" > "$svg"
  fi
  iconset="$work/$icon.iconset"
  mkdir -- "$iconset"
  for size in 16 32 128 256 512; do
    resvg -w "$size" -h "$size" "$svg" "$iconset/icon_${size}x${size}.png"
    resvg -w $((size * 2)) -h $((size * 2)) "$svg" "$iconset/icon_${size}x${size}@2x.png"
  done
  iconutil -c icns -o "$resources/$icon.icns" "$iconset"
done
