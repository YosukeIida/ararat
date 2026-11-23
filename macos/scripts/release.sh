#!/bin/bash
set -euo pipefail

usage() { printf 'usage: release.sh <tag> [--engine <Chromium.app>] [--dry-run]\n'; }
die() { printf 'release: %s\n' "$*" >&2; exit 1; }

[[ "${1:-}" == -h || "${1:-}" == --help ]] && { usage; exit 0; }
[[ $# -ge 1 ]] || { usage >&2; exit 2; }
tag="$1"
shift

scripts="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "$scripts/release-version.sh"
# The devshell's DEVELOPER_DIR names nix's apple-sdk, where /usr/bin/git and codesign find no tools.
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
unset SDKROOT
parse_release_tag "$tag" || die "expected vX.Y.Z or vX.Y.Z-preview.N"

engine="$HOME/chromium-build/src/out/Ararat/Chromium.app"
dry_run=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --engine)
      [[ -n "${2:-}" && "$2" != -* ]] || die "--engine requires a path to Chromium.app"
      engine="$2"
      shift 2
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    *) usage >&2; exit 2 ;;
  esac
done

engine="$(cd -- "$engine" && pwd -P)" || die "engine app directory does not exist"
[[ -d "$engine/Contents/MacOS" ]] || die "no engine app: $engine"
cd -- "$scripts/../.."

changes="$(git status --porcelain --untracked-files=normal)"
[[ -z "$changes" ]] || die "use a clean checkout (including untracked files)"
git fetch --no-tags origin refs/heads/main:refs/remotes/origin/main
head="$(git rev-parse --verify HEAD)"
[[ "$head" == "$(git rev-parse --verify refs/remotes/origin/main)" ]] ||
  die "HEAD must match origin/main"

require_new_tag() {
  local status
  if git ls-remote --exit-code --refs --tags origin "refs/tags/$tag" >/dev/null; then
    die "remote tag already exists: $tag"
  else
    status=$?
    [[ "$status" == 2 ]] || die "could not check remote tag: $tag"
  fi
}
require_new_tag
repo="$(gh repo view "$(git remote get-url origin)" --json nameWithOwner --jq .nameWithOwner)"

nix develop ./nix --no-update-lock-file -c "$scripts/build-core.sh"
(cd macos && swift build -c release)
[[ "$(git rev-parse --verify HEAD)" == "$head" ]] || die "HEAD changed during the build"

out="$(mktemp -d)"
source_archive="$out/Ararat-source.tar.xz"
zip="$out/Ararat-$release_version.zip"
ARARAT_VERSION="$release_version" \
  ARARAT_BUILD_VERSION="$(date -u +%Y%m%d%H%M)" \
  ARARAT_CORRESPONDING_SOURCE_URL="https://github.com/$repo/releases/download/$tag/${source_archive##*/}" \
  "$scripts/bundle-app.sh" --release "$engine" "$out"
ditto -c -k --keepParent "$out/Ararat.app" "$zip"

release_flag=--latest
channel_name=Stable
if [[ "$release_channel" == preview ]]; then
  release_flag=--prerelease
  channel_name=Preview
fi
printf -v notes '%s channel. Unzip the download and move `Ararat.app` to Applications. This build is ad-hoc signed. In Terminal, run `xattr -dr com.apple.quarantine /Applications/Ararat.app`.\n' "$channel_name"
publish=(gh release create "$tag" "$zip" "$source_archive" "$source_archive.sha256"
  --repo "$repo" --target "$head" --title "Ararat $release_display_version" "$release_flag" --notes "$notes")
if [[ "$dry_run" == 1 ]]; then
  printf '%q ' "${publish[@]}"
  printf '\n'
else
  require_new_tag
  "${publish[@]}"
fi
printf 'Release files: %s\n' "$out"
