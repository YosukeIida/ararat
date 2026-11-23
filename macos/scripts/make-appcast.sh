#!/bin/bash
set -euo pipefail

usage() {
  printf 'usage: %s --key-file <private-key-file> <stable|preview> <build-version> <archive-dir>\n' "${0##*/}"
}
die() { printf 'make-appcast: %s\n' "$*" >&2; exit 1; }

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
[[ $# == 5 && "$1" == --key-file ]] || { usage >&2; exit 2; }
[[ "$2" != "-" && -f "$2" && -r "$2" && -s "$2" ]] || die "expected a readable private key file"
key="$(/usr/bin/perl -MCwd=abs_path -e 'print abs_path($ARGV[0]) or die "cannot resolve key path\n"' -- "$2")"
archives="$(cd -- "$5" && pwd -P)"
key_dir="$(cd -- "$(dirname -- "$2")" && pwd -P)"
[[ "$key" != "$archives/"* && "$key_dir/" != "$archives/"* ]] ||
  die "keep the private key outside the archive directory"
[[ "$4" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || die "expected a numeric build version"

args=(--ed-key-file "$key" --versions "$4")
case "$3" in
  stable) ;;
  preview) args+=(--channel preview) ;;
  *) die "expected stable or preview update channel" ;;
esac
if [[ -n "${ARARAT_DOWNLOAD_URL_PREFIX:-}" ]]; then
  args+=(--download-url-prefix "$ARARAT_DOWNLOAD_URL_PREFIX")
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
generator="$script_dir/../.build/artifacts/sparkle/Sparkle/bin/generate_appcast"
[[ -x "$generator" ]] || die "resolve the macos Swift package to install Sparkle's generate_appcast"
exec "$generator" "${args[@]}" "$archives"
