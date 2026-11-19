#!/bin/bash
set -euo pipefail

usage() {
  printf 'usage: %s --keychain-profile <profile> <Ararat.app>\n' "${0##*/}"
  printf '       %s --key <p8> --key-id <id> --issuer <id> [--keychain <path>] <Ararat.app>\n' "${0##*/}"
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
case "${1:-}" in
  --keychain-profile)
    [[ $# == 3 && -n "$2" ]] || { usage >&2; exit 2; }
    credentials=("$1" "$2")
    shift 2
    ;;
  --key)
    [[ $# -ge 7 && -f "$2" && -r "$2" && "$3" == --key-id && -n "$4" && "$5" == --issuer && -n "$6" ]] ||
      { usage >&2; exit 2; }
    credentials=("$1" "$2" "$3" "$4" "$5" "$6")
    shift 6
    if [[ "${1:-}" == --keychain ]]; then
      [[ $# == 3 && -n "$2" ]] || { usage >&2; exit 2; }
      credentials+=("$1" "$2")
      shift 2
    fi
    ;;
  *) usage >&2; exit 2 ;;
esac
[[ $# == 1 ]] || { usage >&2; exit 2; }
app="$(cd -- "$1" && pwd -P)"
[[ -x "$app/Contents/MacOS/Ararat" ]] || { printf 'notarize: expected a bundled Ararat app\n' >&2; exit 1; }
codesign --verify --deep --strict --requirement '=anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists' "$app"

scratch="$(mktemp -d "${TMPDIR:-/tmp}/ararat-notarize.XXXXXX")"
trap 'rm -rf -- "$scratch"' EXIT
ditto -c -k --keepParent "$app" "$scratch/Ararat.zip"
if ! /usr/bin/xcrun notarytool submit "$scratch/Ararat.zip" "${credentials[@]}" --wait --output-format plist > "$scratch/submission.plist"; then
  cat "$scratch/submission.plist" >&2
  exit 1
fi
plutil -p "$scratch/submission.plist"
[[ "$(plutil -extract status raw -o - "$scratch/submission.plist")" == Accepted ]]
/usr/bin/xcrun stapler staple "$app"
/usr/bin/xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"
