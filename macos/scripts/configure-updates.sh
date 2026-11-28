#!/bin/bash

validate_update_configuration() {
  case "$1" in
    https://?*|http://localhost/*|http://localhost:*) ;;
    *) printf 'Expected an HTTPS feed URL or a localhost HTTP test feed\n' >&2; return 1 ;;
  esac
  if [[ ! "${ARARAT_ED_PUBLIC_KEY:-}" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
    printf 'Expected a Base64-encoded EdDSA public key\n' >&2
    return 1
  fi
}

configure_updates() {
  local plist="$1"
  plutil -insert SUFeedURL -string "$2" "$plist"
  plutil -insert SUPublicEDKey -string "$ARARAT_ED_PUBLIC_KEY" "$plist"
  plutil -replace SUVerifyUpdateBeforeExtraction -bool true "$plist"
  plutil -replace SURequireSignedFeed -bool true "$plist"
  plutil -replace SUSignedFeedFailureExpirationInterval -integer 0 "$plist"
}
