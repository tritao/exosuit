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
	--target=wasm32-unknown-wasi \
	--target=wasm32-unknown-emscripten \
	--profile=portable-abi32 \
	--library=terminalkit \
	--interface=TerminalKit \
	--include="$package_dir/include" \
	--source-label=native-packages/terminal/bindings/terminalkit_import.h \
	--output="$output" \
	"$package_dir/bindings/terminalkit_import.h"
