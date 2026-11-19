#!/bin/bash
set -euo pipefail

usage() {
  printf 'usage: %s --identity <Developer ID Application: …|-> [--entitlements <release.plist>] <Ararat.app>\n' "${0##*/}"
}
die() { printf 'sign-release: %s\n' "$*" >&2; exit 1; }

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
[[ $# -ge 3 && "$1" == --identity ]] || { usage >&2; exit 2; }
identity="$2"
shift 2
[[ "$identity" == "-" || "$identity" == 'Developer ID Application: '* ]] ||
  die "expected a Developer ID Application identity or -"
release_entitlements=
if [[ "${1:-}" == --entitlements ]]; then
  [[ $# == 3 && -f "$2" && -r "$2" ]] || { usage >&2; exit 2; }
  release_entitlements="$2"
  plutil -lint "$release_entitlements"
  shift 2
fi
[[ $# == 1 ]] || { usage >&2; exit 2; }

app="$(cd -- "$1" && pwd -P)"
[[ -x "$app/Contents/MacOS/Ararat" ]] || die "expected a bundled Ararat app"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/sign-release.XXXXXX")"
trap 'rm -rf -- "$scratch"' EXIT

sign() {
  local path="$1" name="${2:-}" ent_file
  local args=(--force --sign "$identity")
  if [[ "$identity" != "-" ]]; then
    args+=(--options runtime --timestamp)
    if [[ -n "${ARARAT_SIGNING_KEYCHAIN:-}" ]]; then
      args+=(--keychain "$ARARAT_SIGNING_KEYCHAIN")
    fi
  fi
  if [[ -n "$name" ]]; then
    if [[ "$name" == app-entitlements && -n "$release_entitlements" ]]; then
      ent_file="$release_entitlements"
    else
      ent_file="$scratch/entitlements.plist"
      codesign -d --entitlements - --xml "$path" > "$ent_file"
      [[ -s "$ent_file" ]] || die "missing embedded entitlements on $path"
    fi
    args+=(--entitlements "$ent_file")
  fi
  codesign "${args[@]}" "$path"
}

. "$script_dir/sign-bundle.sh"
sign_bundle "$app"
if [[ "$identity" != "-" ]]; then
  if ! assessment="$(LC_ALL=C spctl --assess --type execute --verbose=2 "$app" 2>&1)"; then
    printf '%s\n' "$assessment" >&2
    [[ "$assessment" == *"source=Unnotarized Developer ID"* ]] || exit 1
    printf 'sign-release: run notarize.sh to complete Gatekeeper verification\n' >&2
  else
    printf '%s\n' "$assessment"
  fi
fi
