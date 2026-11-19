#!/bin/bash
set -euo pipefail

usage() { printf 'usage: %s --keychain-profile <profile> <Ararat.app>\n' "${0##*/}"; }

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
[[ $# == 3 && "$1" == --keychain-profile && -n "$2" ]] || { usage >&2; exit 2; }
app="$(cd -- "$3" && pwd -P)"
[[ -x "$app/Contents/MacOS/Ararat" ]] || { printf 'notarize: expected a bundled Ararat app\n' >&2; exit 1; }
codesign --verify --deep --strict --requirement '=anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists' "$app"

scratch="$(mktemp -d "${TMPDIR:-/tmp}/ararat-notarize.XXXXXX")"
trap 'rm -rf -- "$scratch"' EXIT
ditto -c -k --keepParent "$app" "$scratch/Ararat.zip"
if ! /usr/bin/xcrun notarytool submit "$scratch/Ararat.zip" --keychain-profile "$2" --wait --output-format plist > "$scratch/submission.plist"; then
  cat "$scratch/submission.plist" >&2
  exit 1
fi
plutil -p "$scratch/submission.plist"
[[ "$(plutil -extract status raw -o - "$scratch/submission.plist")" == Accepted ]]
/usr/bin/xcrun stapler staple "$app"
/usr/bin/xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"
