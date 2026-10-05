#!/usr/bin/env bash
set -euo pipefail
root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
haxeon_root=${HAXEON_ROOT:-"$root_dir/haxeon"}
package_dir="$root_dir/native-packages/plugin-host"
output="$package_dir/bindings/exosuit_plugin_host.hxi"
destination=$output
if [[ ${1:-} == --check ]]; then
    destination=$(mktemp)
    trap 'rm -f -- "$destination"' EXIT
elif [[ $# -ne 0 ]]; then
    echo 'usage: scripts/update-plugin-host-bindings.sh [--check]' >&2
    exit 2
fi
"$haxeon_root/scripts/haxeon-ffi-audit" \
    --target=x86_64-linux-gnu --target=x86_64-w64-windows-gnu \
    --target=x86_64-apple-darwin --target=arm64-apple-darwin \
    --profile=portable-abi64 --library=exosuit_plugin_host --interface=ExosuitPluginHost \
    --source-label=include/exosuit_plugin_host.h --output="$destination" \
    "$package_dir/include/exosuit_plugin_host.h"
if [[ ${1:-} == --check ]] && ! cmp -s "$output" "$destination"; then
    echo 'Plugin host bindings are stale; run scripts/update-plugin-host-bindings.sh' >&2
    diff -u "$output" "$destination" || true
    exit 1
fi
