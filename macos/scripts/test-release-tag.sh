#!/bin/bash
set -euo pipefail

. "$(dirname -- "${BASH_SOURCE[0]}")/release-version.sh"

parse_release_tag v0.0.1
set_release_identity
[[ "$release_version|$release_channel|$app_name|$bundle_id|$archive_name" == '0.0.1|stable|Ararat|net.iodine2.ararat|Ararat-0.0.1.zip' ]]
parse_release_tag v0.0.2-preview.12
set_release_identity
[[ "$release_version|$release_channel|$app_name|$bundle_id|$archive_name" == '0.0.2-preview.12|preview|Ararat Preview|net.iodine2.ararat.preview|Ararat-Preview-0.0.2-preview.12.zip' ]]

for tag in v1.2 v1.2.3-preview.0 v1.2.3-preview.01 v1.2.3-beta.1 1.2.3; do
  if parse_release_tag "$tag"; then
    printf 'Expected to reject %s\n' "$tag" >&2
    exit 1
  fi
done
