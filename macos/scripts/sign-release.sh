#!/bin/bash
set -euo pipefail

usage() {
  printf 'usage: %s --identity <Developer ID Application: …|-> [--entitlements <release.plist>] <engine-app> <Ararat.app>\n' "${0##*/}"
}
die() { printf 'sign-release: %s\n' "$*" >&2; exit 1; }

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
[[ $# -ge 4 && "$1" == --identity ]] || { usage >&2; exit 2; }
identity="$2"
shift 2
release_entitlements=
if [[ "$identity" != "-" ]]; then
  [[ "$identity" == 'Developer ID Application: '* ]] || die "expected a Developer ID Application identity"
  [[ $# == 4 && "$1" == --entitlements && -f "$2" && -r "$2" ]] ||
    die "Developer ID signing requires --entitlements <release.plist>"
  release_entitlements="$2"
  plutil -lint "$release_entitlements"
  shift 2
fi
[[ $# == 2 ]] || { usage >&2; exit 2; }

engine_app="$(cd -- "$1" && pwd -P)"
app="$(cd -- "$2" && pwd -P)"
[[ -x "$app/Contents/MacOS/Ararat" ]] || die "expected a bundled Ararat app"
ent_dir="$(cd -- "$engine_app/../../.." && pwd)/chrome/app"
for name in app-entitlements helper-renderer-entitlements helper-gpu-entitlements; do
  [[ -r "$ent_dir/$name.plist" ]] || die "missing $ent_dir/$name.plist"
done

scratch="$(mktemp -d "${TMPDIR:-/tmp}/sign-release.XXXXXX")"
trap 'rm -rf -- "$scratch"' EXIT
entitlements() {
  local name="$1"
  local dst="$scratch/$name.plist" keys key value drop
  cp -- "$ent_dir/$name.plist" "$dst" || return 1
  keys="$(plutil -convert xml1 -o - "$dst" | sed -n 's/^[[:space:]]<key>\(.*\)<\/key>$/\1/p')" || return 1
  # Without a team, ad-hoc signing cannot carry these entitlements.
  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    drop=0
    case "$key" in
      com.apple.application-identifier|keychain-access-groups|\
com.apple.developer.web-browser.public-key-credential|\
com.apple.developer.associated-domains*)
        drop=1 ;;
      *)
        value="$(/usr/libexec/PlistBuddy -c "Print :$key" "$dst")" || return 1
        if [[ "$value" == *TeamIdentifierPrefix* || "$value" == *'${CHROMIUM_TEAM_ID}'* ]]; then
          drop=1
        fi
        ;;
    esac
    if [[ "$drop" == 1 ]]; then
      /usr/libexec/PlistBuddy -c "Delete :$key" "$dst" || return 1
      printf 'sign-release: dropped %s from %s\n' "$key" "$name" >&2
    fi
  done <<< "$keys"
  printf '%s\n' "$dst"
}

sign() {
  local path="$1" name="${2:-}" file
  local args=(--force --sign "$identity")
  if [[ "$identity" != "-" ]]; then
    args+=(--options runtime --timestamp)
  fi
  if [[ -n "$name" ]]; then
    if [[ "$identity" == "-" ]]; then
      file="$(entitlements "$name")"
    elif [[ "$name" == app-entitlements ]]; then
      file="$release_entitlements"
    else
      file="$ent_dir/$name.plist"
    fi
    args+=(--entitlements "$file")
  fi
  codesign "${args[@]}" "$path"
}

fw_root="$app/Contents/Frameworks/Chromium Framework.framework"
fw_ver="$fw_root/Versions/Current"
sparkle_root="$app/Contents/Frameworks/Sparkle.framework"
sparkle_ver="$sparkle_root/Versions/Current"
[[ -d "$fw_ver/Helpers" && -f "$sparkle_ver/Autoupdate" && -d "$sparkle_ver/Updater.app" ]] ||
  die "missing Chromium or Sparkle components in $app"

# Inside out: the framework's dylibs, the bare helper executables, the helper
# apps, the framework, the app. Helpers that load nothing but their share of
# the framework's code carry no entitlements; the renderer and GPU helpers
# carry allow-jit (Aperitif variants ride the same entitlements as the engine's
# own signing model).
for dylib in "$fw_ver"/Libraries/*.dylib; do
  [[ -f "$dylib" ]] || continue
  sign "$dylib"
done
for helper in "$fw_ver"/Helpers/*; do
  [[ -f "$helper" ]] || continue
  [[ "$(file -b "$helper")" == *Mach-O* ]] || continue
  sign "$helper"
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

for service in "$sparkle_ver"/XPCServices/*.xpc; do
  [[ -d "$service" ]] || continue
  sign "$service"
done
sign "$sparkle_ver/Autoupdate"
sign "$sparkle_ver/Updater.app"
sign "$sparkle_root"
sign "$app" app-entitlements

codesign --verify --deep --strict "$app"
if [[ "$identity" != "-" ]]; then
  if ! assessment="$(LC_ALL=C spctl --assess --type execute --verbose=2 "$app" 2>&1)"; then
    printf '%s\n' "$assessment" >&2
    [[ "$assessment" == *"source=Unnotarized Developer ID"* ]] || exit 1
    printf 'sign-release: run notarize.sh to complete Gatekeeper verification\n' >&2
  else
    printf '%s\n' "$assessment"
  fi
fi
