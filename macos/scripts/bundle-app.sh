#!/bin/bash
# Builds Ararat.app from the engine's Chromium.app and our Ararat launcher:
# bundle-app.sh [--release] <engine-app> <out-dir>
#
# <engine-app> is the built engine, e.g. ~/chromium-build/src/out/Ararat/Chromium.app.
# Our executable comes from this package's SwiftPM build products (run
# `swift build -c release` in macos/ first). Everything is signed ad-hoc inside
# out, no hardened runtime: helpers first, then the framework, then the app.
set -euo pipefail

usage() {
  cat <<'USAGE'
usage: bundle-app.sh [--release] <engine-app> <out-dir>

Copies the engine's Chromium.app to <out-dir>/Ararat.app, puts this package's
Ararat executable in Contents/MacOS (build it first: swift build -c release in
macos/), renames the bundle id to net.iodine2.ararat and signs everything
ad-hoc inside out with the engine's entitlements (renderer and GPU helpers
carry allow-jit; the app the app entitlements; entitlements that need a team
are dropped). The bundle name and display name are Ararat; helper names stay Chromium.

With --release, use a clean release checkout, verify the engine tree against
the recorded manifest and emit Corresponding Source before staging Ararat.app.
USAGE
}

die() { printf 'bundle-app: %s\n' "$*" >&2; exit 1; }

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
release=0
if [[ "${1:-}" == --release ]]; then
  release=1
  shift
fi
[[ $# == 2 ]] || { usage >&2; exit 2; }
[[ -n "$2" ]] || die "empty out-dir"

engine_app="$(cd -- "$1" && pwd)"
out_dir="$2"
[[ -d "$engine_app/Contents/MacOS" ]] || die "no engine app: $engine_app"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
package_dir="$(cd -- "$script_dir/.." && pwd)"
exe="$package_dir/.build/release/Ararat"

# The engine's entitlements live in its source tree (the ad-hoc engine build
# signs nothing, so no compiled copies exist under out/); gen/chrome would
# carry them only in a build that signs.
engine_src="$(cd -- "$engine_app/../../.." && pwd)"
if [[ "$release" == 1 ]]; then
  changes="$(git -C "$package_dir" status --porcelain --untracked-files=normal)"
  [[ -z "$changes" ]] || die "use a clean checkout before bundling a release (including untracked files)"
  env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin ARARAT_SRC_DIR="$engine_src" \
    ARARAT_BUILD_ROOT="$(dirname -- "$engine_src")" \
    /bin/bash "$package_dir/../engine/scripts/series-check" --release
elif [[ ! -x "$exe" ]]; then
  exe="$package_dir/.build/debug/Ararat"
fi
[[ -x "$exe" ]] || die "no Ararat executable: run swift build -c release in $package_dir"

ent_dir="$engine_src/chrome/app"
[[ -r "$ent_dir/app-entitlements.plist" ]] || die "no engine entitlements at $ent_dir (pass an engine built from a Chromium checkout)"

if [[ "$release" == 1 ]]; then
  /bin/bash "$package_dir/../engine/scripts/corresponding-source" "$out_dir/Ararat-source"
fi

app="$out_dir/Ararat.app"
rm -rf -- "$app"
mkdir -p -- "$out_dir"
cp -R -- "$engine_app" "$app"

rm -f -- "$app/Contents/MacOS/Chromium"
cp -- "$exe" "$app/Contents/MacOS/Ararat"

plist="$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable Ararat" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName Ararat" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Ararat" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier net.iodine2.ararat" "$plist"

# Team-bound entitlements fail ad-hoc signing (their values carry a team
# prefix); they are dropped and named, not kept.
scratch="$(mktemp -d "${TMPDIR:-/tmp}/bundle-app.XXXXXX")"
trap 'rm -rf -- "$scratch"' EXIT
entitlements() { # entitlements <name> -> filtered plist path
  local name="$1"
  # separate declaration: the words of one local statement are expanded before
  # any of its assignments land, so $name here would read a caller's `name`
  local src="$ent_dir/$name.plist" dst="$scratch/$name.plist" key value drop
  [[ -r "$src" ]] || { printf 'bundle-app: missing entitlements %s\n' "$src" >&2; return 1; }
  cp -- "$src" "$dst"
  # Team-bound entitlements fail ad-hoc signing: their values carry a team
  # prefix and there is no team. Dropped by key name, or by value for any key
  # a rebase renames; every drop is named on stderr — stdout is the plist path.
  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    drop=0
    case "$key" in
      com.apple.application-identifier|keychain-access-groups|\
com.apple.developer.web-browser.public-key-credential|\
com.apple.developer.associated-domains*)
        drop=1 ;;
      *)
        value="$(/usr/libexec/PlistBuddy -c "Print :$key" "$dst" 2>/dev/null)"
        if [[ "$value" == *TeamIdentifierPrefix* || "$value" == *'${CHROMIUM_TEAM_ID}'* ]]; then
          drop=1
        fi
        ;;
    esac
    if [[ "$drop" == 1 ]]; then
      /usr/libexec/PlistBuddy -c "Delete :$key" "$dst"
      printf 'bundle-app: dropped %s from %s\n' "$key" "$name" >&2
    fi
  done < <(plutil -convert xml1 -o - "$dst" | sed -n 's/[[:space:]]*<key>\(.*\)<\/key>/\1/p')
  printf '%s\n' "$dst"
}

sign() { # sign <path> <entitlements-name or "">
  local path="$1" file
  if [[ -n "${2:-}" ]]; then
    file="$(entitlements "$2")"
    codesign --force --sign - --entitlements "$file" "$path"
  else
    codesign --force --sign - "$path"
  fi
}

framework="$(cd -- "$app/Contents/Frameworks" && ls -d *.framework | head -n1)"
fw_root="$app/Contents/Frameworks/$framework"
[[ -n "$framework" ]] || die "no framework in the engine app"
versions="$(cd -- "$fw_root/Versions" && ls | grep -vx Current | head -n1)"
fw_ver="$fw_root/Versions/$versions"

# Inside out: the framework's dylibs, the bare helper executables, the helper
# apps, the framework, the app. Helpers that load nothing but their share of
# the framework's code carry no entitlements; the renderer and GPU helpers
# carry allow-jit (Aperitif variants ride the same entitlements as the engine's
# own signing model).
for dylib in "$fw_ver"/Libraries/*.dylib; do
  [[ -e "$dylib" ]] && sign "$dylib" ""
done
for helper in "$fw_ver"/Helpers/*; do
  [[ -f "$helper" ]] || continue
  file -b "$helper" | grep -q "Mach-O" && sign "$helper" ""
done
for helper_app in "$fw_ver"/Helpers/*.app; do
  case "$(basename -- "$helper_app")" in
    *"Helper (Renderer).app"|*"Helper (Aperitif Renderer).app") ent=helper-renderer-entitlements ;;
    *"Helper (GPU).app"|*"Helper (Aperitif GPU).app") ent=helper-gpu-entitlements ;;
    *) ent="" ;;
  esac
  sign "$helper_app" "$ent"
done
sign "$fw_root" ""

sign "$app" app-entitlements

codesign --verify --deep --strict "$app"
printf 'bundle-app: %s ready\n' "$app"
