#!/usr/bin/env bash
set -euo pipefail
root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
haxeon_root=${HAXEON_ROOT:-"$root_dir/haxeon"}
output="$root_dir/bindings/pragtical_hx.hxi"
destination=$output
if [[ ${1:-} == --check ]]; then
    destination=$(mktemp)
    trap 'rm -f -- "$destination"' EXIT
elif [[ $# -ne 0 ]]; then
    echo 'usage: scripts/update-native-bindings.sh [--check]' >&2
    exit 2
fi
"$haxeon_root/scripts/haxeon-ffi-audit" \
    --target=x86_64-linux-gnu --target=x86_64-w64-windows-gnu \
    --target=x86_64-apple-darwin --target=arm64-apple-darwin \
    --profile=portable-abi64 --library=pragtical_hx --interface=PragticalHx \
    --source-label=include/pragtical_hx/native.h --output="$destination" \
    "$root_dir/include/pragtical_hx/native.h"
if [[ ${1:-} == --check ]] && ! cmp -s "$output" "$destination"; then
    echo 'Native bindings are stale; run scripts/update-native-bindings.sh' >&2
    diff -u "$output" "$destination" || true
    exit 1
fi
