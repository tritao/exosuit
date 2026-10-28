#!/usr/bin/env bash
set -euo pipefail

package_dir=$(cd "$(dirname "$0")/.." && pwd)
haxeon_root=${HAXEON_ROOT:-"$package_dir/../../haxeon"}
output="$package_dir/bindings/processkit.hxi"
if [[ ${1:-} == --check ]]; then
    output=$(mktemp)
    trap 'rm -f -- "$output"' EXIT
elif [[ $# -ne 0 ]]; then
    echo "usage: tools/update-hxi.sh [--check]" >&2
    exit 2
fi

"$haxeon_root/scripts/haxeon-ffi-audit" \
    --target=x86_64-linux-gnu \
    --target=x86_64-w64-windows-gnu \
    --target=x86_64-apple-darwin \
    --target=arm64-apple-darwin \
    --profile=portable-abi64 \
    --library=processkit \
    --interface=ProcessKit \
    --include="$package_dir/include" \
    --source-label=native-packages/processes/bindings/processkit_import.h \
    --output="$output" \
    "$package_dir/bindings/processkit_import.h"

if [[ ${1:-} == --check ]] && ! cmp -s "$package_dir/bindings/processkit.hxi" "$output"; then
    echo "ProcessKit HXI is stale" >&2
    diff -u "$package_dir/bindings/processkit.hxi" "$output" || true
    exit 1
fi
