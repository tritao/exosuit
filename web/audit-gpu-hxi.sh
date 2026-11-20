#!/usr/bin/env bash
# Writes the GPU kit's FFI interface to the path given as --output=PATH, with the arguments of haxeon/packages/gpu/tools/update-haxeon-hxi.sh
# (which writes only its committed file). generate-wasm-hxi.sh runs this against its wasm32 audit shim.
set -euo pipefail

haxeon_dir=${HAXEON_DIR:?HAXEON_DIR is required}
real_dir=${HAXEON_REAL_DIR:-$haxeon_dir}
nativekit_dir=${NATIVEKIT_DIR:-"$real_dir/vendor/nativekit"}
platform_dir="$real_dir/packages/platform"
gpu_dir="$real_dir/packages/gpu"

"$haxeon_dir/scripts/haxeon-ffi-audit" \
    --target=x86_64-linux-gnu \
    --target=x86_64-w64-windows-gnu \
    --target=x86_64-apple-darwin \
    --target=arm64-apple-darwin \
    --profile=portable-abi64 \
    --library=nativekit_gpu \
    --interface=NativeKitGpu \
    --depends=NativeKit \
    --dependency-hxi="$platform_dir/bindings/nativekit.hxi" \
    --include="$nativekit_dir/modules/gpu/include" \
    --include="$gpu_dir/bindings" \
    --include="$nativekit_dir/include" \
    --exclude-header="$nativekit_dir/include/nativekit.h" \
    --exclude-header="$nativekit_dir/include/nativekit_graphics.h" \
    --source-label=modules/gpu/bindings/nativekit_gpu_import.h \
    "$@" \
    "$gpu_dir/bindings/nativekit_gpu_import.h"
