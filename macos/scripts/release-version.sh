#!/bin/bash

parse_release_tag() {
  [[ "$1" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)(-preview\.([1-9][0-9]*))?$ ]] || return 1
  release_version="${1#v}"
  release_channel=stable
  if [[ -n "${BASH_REMATCH[3]}" ]]; then
    release_channel=preview
  fi
}

set_release_identity() {
  app_name=Ararat
  bundle_id=net.iodine2.ararat
  archive_name="Ararat-$release_version.zip"
  channel_name=Stable
  if [[ "$release_channel" == preview ]]; then
    app_name="Ararat Preview"
    bundle_id=net.iodine2.ararat.preview
    archive_name="Ararat-Preview-$release_version.zip"
    channel_name=Preview
  fi
}
