#!/bin/sh
set -eu

fail() { printf '%s\n' 'Deployer dependency checksum verification failed.' >&2; exit 1; }

# One argument validates a mandatory reviewed input before any downloads.
# Two arguments also verify the downloaded bytes before installation/extraction.
case "$#" in 1|2) ;; *) fail ;; esac
expected=$1
[ "${#expected}" -eq 64 ] || fail
case "$expected" in *[!0-9a-f]*) fail ;; esac
if [ "$#" -eq 1 ]; then exit 0; fi
[ -f "$2" ] || fail
actual=$(sha256sum < "$2") || fail
actual=${actual%% *}
[ "$actual" = "$expected" ] || fail
