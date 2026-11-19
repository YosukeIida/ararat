#!/bin/bash
set -euo pipefail

usage() {
  cat <<'USAGE'
usage: bundle-app.sh [--release] <engine-app> <out-dir>

Builds an ad-hoc signed Ararat.app using the matching SwiftPM executable and
Sparkle framework. ARARAT_FEED_URL and ARARAT_ED_PUBLIC_KEY enable updating.
ARARAT_UPDATE_CHANNEL is stable (default) or nightly. ARARAT_BUILD_VERSION
overrides CFBundleVersion and is required for builds that enable updating.

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

products_dir="$(cd -- "$(dirname -- "$exe")" && pwd -P)"
sparkle="$products_dir/Sparkle.framework"
[[ -d "$sparkle" ]] || die "missing Sparkle.framework in $products_dir"

channel="${ARARAT_UPDATE_CHANNEL:-stable}"
case "$channel" in stable|nightly) ;; *) die "expected stable or nightly update channel" ;; esac
version="${ARARAT_BUILD_VERSION:-}"
if [[ -n "$version" && ! "$version" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
  die "expected a numeric ARARAT_BUILD_VERSION"
fi
if [[ -n "${ARARAT_FEED_URL:-}" || -n "${ARARAT_ED_PUBLIC_KEY:-}" ]]; then
  [[ -n "${ARARAT_FEED_URL:-}" && -n "${ARARAT_ED_PUBLIC_KEY:-}" && -n "$version" ]] ||
    die "updates require ARARAT_FEED_URL, ARARAT_ED_PUBLIC_KEY and ARARAT_BUILD_VERSION"
  case "$ARARAT_FEED_URL" in
    https://?*|http://localhost/*|http://localhost:*) ;;
    *) die "expected an HTTPS feed URL or a localhost HTTP test feed" ;;
  esac
  [[ "$ARARAT_ED_PUBLIC_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]] ||
    die "expected a Base64-encoded EdDSA public key"
fi

if [[ "$release" == 1 ]]; then
  /bin/bash "$package_dir/../engine/scripts/corresponding-source" "$out_dir/Ararat-source"
fi

app="$out_dir/Ararat.app"
rm -rf -- "$app"
mkdir -p -- "$out_dir"
cp -R -- "$engine_app" "$app"

rm -f -- "$app/Contents/MacOS/Chromium"
cp -- "$exe" "$app/Contents/MacOS/Ararat"
ditto "$sparkle" "$app/Contents/Frameworks/Sparkle.framework"
cp -- "$package_dir/.build/artifacts/sparkle/Sparkle/LICENSE" "$app/Contents/Resources/Sparkle-LICENSE.txt"

plist="$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable Ararat" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName Ararat" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Ararat" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier net.iodine2.ararat" "$plist"

for key in SUFeedURL SUPublicEDKey AraratUpdateChannel SURequireSignedFeed SUVerifyUpdateBeforeExtraction SUSignedFeedFailureExpirationInterval; do
  if plutil -extract "$key" xml1 -o /dev/null "$plist" 2>/dev/null; then
    plutil -remove "$key" "$plist"
  fi
done
if [[ -n "$version" ]]; then
  # Chromium locates its versioned framework via CFBundleShortVersionString.
  plutil -replace CFBundleVersion -string "$version" "$plist"
fi
if [[ -n "${ARARAT_FEED_URL:-}" ]]; then
  plutil -insert SUFeedURL -string "$ARARAT_FEED_URL" "$plist"
  plutil -insert SUPublicEDKey -string "$ARARAT_ED_PUBLIC_KEY" "$plist"
  plutil -insert AraratUpdateChannel -string "$channel" "$plist"
  plutil -replace SUVerifyUpdateBeforeExtraction -bool true "$plist"
  plutil -replace SURequireSignedFeed -bool true "$plist"
  plutil -replace SUSignedFeedFailureExpirationInterval -integer 0 "$plist"
fi

"$script_dir/sign-release.sh" --identity - "$engine_app" "$app"
printf 'bundle-app: %s ready\n' "$app"
