#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: tools/generate-wasm-hxi.sh OUTPUT" >&2
    exit 2
fi

package_dir=$(cd "$(dirname "$0")/.." && pwd)
haxeon_root=${HAXEON_DIR:-${HAXEON_ROOT:-"$package_dir/../../haxeon"}}
output=$1
mkdir -p "$(dirname "$output")"

"$haxeon_root/scripts/haxeon-ffi-audit" \
    --target=x86_64-linux-gnu \
    --target=x86_64-w64-windows-gnu \
    --target=x86_64-apple-darwin \
    --target=arm64-apple-darwin \
    --profile=portable-abi64 \
    --library=textmate_regex \
    --interface=TextMateRegex \
    --include="$package_dir/include" \
    --source-label=native-packages/oniguruma/bindings/textmate_regex_import.h \
    --output="$output" \
    "$package_dir/bindings/textmate_regex_import.h"
