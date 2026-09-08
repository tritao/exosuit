#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
archive=$($root_dir/scripts/package-release.sh)
fixture=$(mktemp -d)
trap 'find "$fixture" -depth -delete' EXIT
tar -C "$fixture" -xzf "$archive"
install_dir=$(find "$fixture" -mindepth 1 -maxdepth 1 -type d -name 'pragtical-haxeon-*' -print -quit)
[[ -n "$install_dir" ]]

if readelf -d "$install_dir/pragtical-haxeon" "$install_dir/pragtical_hx.hdll" "$install_dir/realtime_runtime.hdll" | grep -F "$root_dir"; then
	echo "release artifact contains a source-tree runtime search path" >&2
	exit 1
fi

portable="$fixture/portable state"
(
	cd "$fixture"
	PRAGTICAL_PORTABLE="$portable" xvfb-run -a "$install_dir/pragtical-haxeon" --smoke-frames=3
)
[[ -d "$portable" ]]
echo "PASS: unpacked graphical artifact launched outside the source tree"

HAXEON_LSP="$install_dir/tools/haxeon-lsp" "$root_dir/scripts/test-haxeon-lsp.sh"
echo "PASS: unpacked artifact completed the real Haxeon language-service route"
