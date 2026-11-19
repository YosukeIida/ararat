#!/bin/bash
set -euo pipefail

[[ $# == 1 && "${ARARAT_TEST_VM:-}" == ararat-test ]] || {
  printf 'On the disposable ararat-test VM, run ARARAT_TEST_VM=ararat-test %s <engine-app>\n' "${0##*/}" >&2
  exit 2
}
command -v uv >/dev/null
scripts="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
umask 077
scratch="$(mktemp -d "${TMPDIR:?}/ararat-update.XXXXXX")"
server=
trap 'if [[ -n "$server" ]]; then kill "$server" 2>/dev/null || true; fi' EXIT
printf 'Test files and logs are in %s\n' "$scratch"
mkdir -p "$scratch/feed" "$scratch/home"

export ARARAT_FEED_URL=http://localhost:8765/appcast.xml
ARARAT_ED_PUBLIC_KEY="$(env -u DEVELOPER_DIR -u SDKROOT /usr/bin/swift - "$scratch/private-key" <<'SWIFT'
import CryptoKit
import Foundation

let key = Curve25519.Signing.PrivateKey()
try key.rawRepresentation.base64EncodedData().write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print(key.publicKey.rawRepresentation.base64EncodedString())
SWIFT
)"
export ARARAT_ED_PUBLIC_KEY ARARAT_UPDATE_CHANNEL=nightly
ARARAT_BUILD_VERSION=1000 "$scripts/bundle-app.sh" "$1" "$scratch/installed"
ARARAT_BUILD_VERSION=1001 "$scripts/bundle-app.sh" "$1" "$scratch/candidate"
app="$scratch/installed/Ararat.app"
plist="$app/Contents/Info.plist"
[[ "$(plutil -extract CFBundleVersion raw -o - "$plist")" == 1000 ]]

# Stage the update for install on quit so Sparkle does not relaunch Chromium without --use-mock-keychain.
plutil -replace SUEnableAutomaticChecks -bool true "$plist"
plutil -replace SUAutomaticallyUpdate -bool true "$plist"
"$scripts/sign-release.sh" --identity - "$1" "$app"
ditto -c -k --keepParent "$scratch/candidate/Ararat.app" "$scratch/feed/Ararat-1001.zip"
CFFIXED_USER_HOME="$scratch/home" "$scripts/make-appcast.sh" --key-file "$scratch/private-key" nightly 1001 "$scratch/feed"
rm -- "$scratch/private-key"
grep -q '<sparkle:channel>nightly</sparkle:channel>' "$scratch/feed/appcast.xml"

uv run --no-project python -m http.server 8765 --bind 127.0.0.1 --directory "$scratch/feed" > "$scratch/http.log" 2>&1 &
server=$!
for ((i = 0; i < 30; i++)); do
  kill -0 "$server"
  if curl --fail --silent --output /dev/null "$ARARAT_FEED_URL"; then break; fi
  sleep 1
done
curl --fail --silent --show-error "$ARARAT_FEED_URL" | cmp - "$scratch/feed/appcast.xml"

cat <<'STEPS'
Wait for the background download to finish. Choose Check for Updates… to see
the staged update, select Install on Quit, then quit Ararat with Command-Q.
Use Install on Quit so the app never launches without the mock Keychain flag.
STEPS
CFFIXED_USER_HOME="$scratch/home" "$app/Contents/MacOS/Ararat" --use-mock-keychain \
  --user-data-dir="$scratch/profile" --ararat-db="$scratch/workspace.sqlite" > "$scratch/browser.log" 2>&1

for ((i = 0; i < 60; i++)); do
  if [[ "$(plutil -extract CFBundleVersion raw -o - "$plist" 2>/dev/null)" == 1001 ]]; then
    codesign --verify --deep --strict "$app"
    grep -q 'GET /Ararat-1001.zip' "$scratch/http.log"
    printf 'Build 1000 found and installed build 1001.\n'
    exit 0
  fi
  sleep 1
done
printf 'Ararat did not install build 1001. See %s\n' "$scratch" >&2
exit 1
