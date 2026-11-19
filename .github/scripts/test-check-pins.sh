#!/bin/sh
set -eu

cd "$(dirname "$0")"
uv run --no-project python check-pins.py fixtures/pinned.yml
if output=$(uv run --no-project python check-pins.py fixtures/unpinned.yml 2>&1); then
  echo 'Expected unpinned actions to fail the check' >&2
  exit 1
fi
for line in 4 5 6 7 9; do
  printf '%s\n' "$output" | grep -q "^fixtures/unpinned.yml:$line: uses must pin a full 40-hex commit SHA$"
done
