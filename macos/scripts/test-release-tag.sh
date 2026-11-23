#!/bin/bash
set -euo pipefail

. "$(dirname -- "${BASH_SOURCE[0]}")/release-version.sh"

parse_release_tag v0.0.1
[[ "$release_version|$release_channel|$release_display_version" == '0.0.1|stable|0.0.1' ]]
parse_release_tag v0.0.2-preview.12
[[ "$release_version|$release_channel|$release_display_version" == '0.0.2-preview.12|preview|0.0.2 Preview 12' ]]

for tag in v1.2 v1.2.3-preview.0 v1.2.3-preview.01 v1.2.3-beta.1 1.2.3; do
  if parse_release_tag "$tag"; then
    printf 'Expected to reject %s\n' "$tag" >&2
    exit 1
  fi
done
