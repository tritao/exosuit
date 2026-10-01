#!/usr/bin/env bash
set -euo pipefail
package_dir=$(cd "$(dirname "$0")/.." && pwd)
haxeon_root=${HAXEON_ROOT:-"$package_dir/../../../haxeon"}
build_dir="$package_dir/tests/build/native"
"$package_dir/tools/update-hxi.sh" --check
cmake -S "$package_dir" -B "$build_dir" -G Ninja -DCMAKE_BUILD_TYPE=Debug
cmake --build "$build_dir" -j 4
ctest --test-dir "$build_dir" --output-on-failure
self_hosted=()
if [[ ${HAXEON_SELF_HOSTED:-0} == 1 ]]; then self_hosted+=(--self-hosted); fi
"$haxeon_root/scripts/haxeon" run --project "$package_dir/tests/haxeon.json" \
    "${self_hosted[@]}"
