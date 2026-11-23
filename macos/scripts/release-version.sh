#!/bin/bash

parse_release_tag() {
  [[ "$1" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)(-preview\.([1-9][0-9]*))?$ ]] || return 1
  release_version="${1#v}"
  release_channel=stable
  release_display_version="${BASH_REMATCH[1]}"
  if [[ -n "${BASH_REMATCH[3]}" ]]; then
    release_channel=preview
    release_display_version+=" Preview ${BASH_REMATCH[3]}"
  fi
}
