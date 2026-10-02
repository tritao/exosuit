#!/usr/bin/env bash
# Optional composed browser gate; missing platform tools stay pending.
set -euo pipefail
root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
if [[ ${EXOSUIT_CI_WEB:-0} != 1 ]]; then
	echo "PENDING: browser gate (set EXOSUIT_CI_WEB=1)"
	exit 0
fi
emsdk_dir=${EMSDK_DIR:-"$root_dir/../nativekit/.tools/emsdk"}
if [[ ! -f "$emsdk_dir/emsdk_env.sh" ]]; then
	echo "PENDING: browser gate (Emscripten unavailable at $emsdk_dir)"
	exit 0
fi
browser=${EXOSUIT_WEB_BROWSER:-}
if [[ -z "$browser" ]]; then
	for candidate in google-chrome chromium chromium-browser; do
		if command -v "$candidate" >/dev/null 2>&1; then
			browser=$(command -v "$candidate")
			break
		fi
	done
fi
if [[ -z "$browser" ]] || ! command -v "$browser" >/dev/null 2>&1; then
	echo "PENDING: browser gate (Chrome unavailable)"
	exit 0
fi
# Emscripten supplies Node even when it is not on the invoking shell's PATH.
(
    source "$emsdk_dir/emsdk_env.sh" >/dev/null 2>&1
    "${EXOSUIT_WEB_NODE:-node}" "$root_dir/web/tools/test-launcher-lifecycle.cjs"
)
for target in wasm32 wasm-gc; do
	build_dir="$root_dir/build/web-ci-$target"
	EXOSUIT_WEB_TARGET="$target" EXOSUIT_WEB_BUILD_DIR="$build_dir" "$root_dir/web/build.sh"
	EXOSUIT_WEB_SITE_DIR="$build_dir/site" EXOSUIT_WEB_BROWSER="$browser" "$root_dir/web/test.sh"
done
