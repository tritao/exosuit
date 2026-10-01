#!/usr/bin/env bash
set -euo pipefail
package_dir=$(cd "$(dirname "$0")/.." && pwd)
haxeon_root=${HAXEON_ROOT:-"$package_dir/../../../../haxeon"}
nativekit_root=$(cd "$package_dir/../../../../nativekit" && pwd)
nativekit_build="$package_dir/tests/build/nativekit"
cmake -S "$nativekit_root" -B "$nativekit_build" -G Ninja \
    -DNK_BUILD_TESTS=OFF -DNK_BUILD_EXAMPLES=OFF -DNK_BUILD_GPU=OFF \
    -DCMAKE_BUILD_TYPE=Debug >/dev/null
cmake --build "$nativekit_build" --target nativekit -j 4 >/dev/null
export LD_LIBRARY_PATH="$nativekit_build${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
self_hosted=()
if [[ ${HAXEON_SELF_HOSTED:-0} == 1 ]]; then self_hosted+=(--self-hosted); fi
"$haxeon_root/scripts/haxeon" run --project "$package_dir/tests/haxeon.json" \
    "${self_hosted[@]}"
