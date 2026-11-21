#!/bin/sh
set -eu

if [ "$#" -ne 2 ] || [ ! -f "$1" ] || [ ! -f "$2" ]; then
    echo 'Usage: check-arc-password-output.sh STDOUT STDERR' >&2
    exit 2
fi

if /usr/bin/grep -Fq \
    -e 'arc-fixture-11' -e 'arc-fixture-32' -e 'ararat-own-31' \
    -e 'arc "fixture", 12' -e 'arc \"fixture\", 12' \
    -e 'v10notencrypted' -e 'v11whatever' -e 'fixture-arc-secret' -- "$1" "$2"; then
    echo 'Arc password fixture material found in process output' >&2
    exit 1
else
    test "$?" -eq 1
fi
