#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
skribidi_source=$(cd "$root_dir/../haxeon/packages/ui/vendor/skribidi" && pwd)
build_dir=${SKRIBIDI_LAYOUT_TEST_BUILD_DIR:-"$root_dir/build/skribidi-layout-tests"}

cmake -S "$root_dir/experiments/skribidi_edit_window" -B "$build_dir" \
    -DSKRIBIDI_SOURCE="$skribidi_source" -DCMAKE_BUILD_TYPE=Release
cmake --build "$build_dir" --target edit_window_probe \
    --parallel "${CMAKE_BUILD_PARALLEL_LEVEL:-4}"
env -u SKB_NATIVE_ONLY "$build_dir/edit_window_probe"
echo "PASS: native text layout differential and shared snapshot lifetime"
