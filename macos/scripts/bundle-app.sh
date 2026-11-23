#!/bin/bash
set -euo pipefail

usage() {
  cat <<'USAGE'
usage: bundle-app.sh [--release] <engine-app> <out-dir>
       bundle-app.sh --from-artifact <dir> <out-dir>

Builds an ad-hoc signed Ararat.app using the matching SwiftPM executable and
Sparkle framework. ARARAT_FEED_URL and ARARAT_ED_PUBLIC_KEY enable updating.
ARARAT_UPDATE_CHANNEL is stable (default) or nightly. ARARAT_BUILD_VERSION
overrides CFBundleVersion and is required for builds that enable updating.
ARARAT_CORRESPONDING_SOURCE_URL is the HTTPS address of the release source archive.

With --release, use a clean release checkout, verify the engine tree against
the recorded manifest and emit Corresponding Source before staging Ararat.app.
With --from-artifact, use <dir>/out/Ararat/Chromium.app and verify
<dir>/provenance.json against the current commit.
USAGE
}

die() { printf 'bundle-app: %s\n' "$*" >&2; exit 1; }

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
release=0
from_artifact=0
if [[ "${1:-}" == --release ]]; then
  release=1
  shift
elif [[ "${1:-}" == --from-artifact ]]; then
  from_artifact=1
  shift
fi
[[ $# == 2 ]] || { usage >&2; exit 2; }
[[ -n "$2" ]] || die "empty out-dir"

engine_path="$1"
if [[ "$from_artifact" == 1 ]]; then
  engine_path="$1/out/Ararat/Chromium.app"
fi
engine_app="$(cd -- "$engine_path" && pwd)"
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
elif [[ "$from_artifact" == 1 ]]; then
  provenance="$engine_src/provenance.json"
  key="$(/bin/bash "$package_dir/../engine/scripts/engine-key")"
  patch_state="$(git -C "$package_dir" show HEAD:engine/patch-state.sha256 | shasum -a 256 | cut -d ' ' -f 1)"
  [[ "$(/usr/bin/plutil -extract engine_key raw -expect string -o - -- "$provenance")" == "$key" ]] ||
    die "artifact engine_key differs from $key or is missing"
  [[ "$(/usr/bin/plutil -extract patch_state_sha256 raw -expect string -o - -- "$provenance")" == "$patch_state" ]] ||
    die "artifact patch_state_sha256 differs from the recorded manifest or is missing"
elif [[ ! -x "$exe" ]]; then
  exe="$package_dir/.build/debug/Ararat"
fi
[[ -x "$exe" ]] || die "no Ararat executable: run swift build -c release in $package_dir"

ent_dir="$engine_src/chrome/app"
for name in app-entitlements helper-renderer-entitlements helper-gpu-entitlements; do
  [[ -r "$ent_dir/$name.plist" ]] || die "missing $ent_dir/$name.plist"
done

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
  . "$script_dir/configure-updates.sh"
  validate_update_configuration
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
cp -- "$package_dir/../LICENSE" "$app/Contents/Resources/Ararat-LICENSE.txt"
cp -- "$package_dir/../third_party/ardia/LICENSE" "$app/Contents/Resources/Ardia-LICENSE.txt"
cp -- "$package_dir/../third_party/ardia/LICENSE.Apache-2.0" "$app/Contents/Resources/Ardia-LICENSE.Apache-2.0.txt"
cp -- "$package_dir/../third_party/ardia/NOTICE" "$app/Contents/Resources/Ardia-NOTICE.txt"
cp -- "$package_dir/../third_party/cra/LICENSE" "$app/Contents/Resources/Cra-LICENSE.txt"
cp -- "$package_dir/../third_party/yab/LICENSE" "$app/Contents/Resources/Yab-LICENSE.txt"
cp -- "$package_dir/../third_party/yab/NOTICE" "$app/Contents/Resources/Yab-NOTICE.txt"
cp -- "$package_dir/.build/artifacts/sparkle/Sparkle/LICENSE" "$app/Contents/Resources/Sparkle-LICENSE.txt"

plist="$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable Ararat" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName Ararat" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Ararat" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier net.iodine2.ararat" "$plist"

# Why keep the original value: the launcher must load the exact Chromium build it ships.
framework_version="$(plutil -extract CFBundleShortVersionString raw -expect string -o - "$plist")"
[[ -f "$app/Contents/Frameworks/Chromium Framework.framework/Versions/$framework_version/Chromium Framework" ]] ||
  die "missing Chromium framework for version $framework_version"
plutil -insert AraratChromiumVersion -string "$framework_version" "$plist"
plutil -replace CFBundleShortVersionString -string 0.0.1 "$plist"

for key in SUFeedURL SUPublicEDKey AraratUpdateChannel SURequireSignedFeed SUVerifyUpdateBeforeExtraction SUSignedFeedFailureExpirationInterval; do
  if plutil -extract "$key" xml1 -o /dev/null "$plist" 2>/dev/null; then
    plutil -remove "$key" "$plist"
  fi
done
if [[ -n "$version" ]]; then
  plutil -replace CFBundleVersion -string "$version" "$plist"
fi
if [[ -n "${ARARAT_CORRESPONDING_SOURCE_URL:-}" ]]; then
  [[ "$ARARAT_CORRESPONDING_SOURCE_URL" == https://?* ]] || die "set an HTTPS source archive URL"
  plutil -insert AraratCorrespondingSourceURL -string "$ARARAT_CORRESPONDING_SOURCE_URL" "$plist"
elif [[ "$release" == 1 ]]; then
  plutil -insert AraratLocalCorrespondingSource -bool true "$plist"
fi
if [[ -n "${ARARAT_FEED_URL:-}" ]]; then
  configure_updates "$plist" "$channel"
fi

scratch="$(mktemp -d "${TMPDIR:-/tmp}/bundle-app.XXXXXX")"
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
        if [[ "$value" == *TeamIdentifierPrefix* || "$value" == *"\${CHROMIUM_TEAM_ID}"* ]]; then
          drop=1
        fi
        ;;
    esac
    if [[ "$drop" == 1 ]]; then
      /usr/libexec/PlistBuddy -c "Delete :$key" "$dst" || return 1
      printf 'bundle-app: dropped %s from %s\n' "$key" "$name" >&2
    fi
  done <<< "$keys"
  printf '%s\n' "$dst"
}

sign() {
  local path="$1" name="${2:-}" ent_file
  if [[ -n "$name" ]]; then
    ent_file="$(entitlements "$name")"
    codesign --force --sign - --entitlements "$ent_file" "$path"
  else
    codesign --force --sign - "$path"
  fi
}

. "$script_dir/sign-bundle.sh"
sign_bundle "$app"
printf 'bundle-app: %s ready\n' "$app"
