#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
archive=$($root_dir/scripts/package-release.sh)
fixture=$(mktemp -d)
trap 'find "$fixture" -depth -delete' EXIT
tar -C "$fixture" -xzf "$archive"
install_dir=$(find "$fixture" -mindepth 1 -maxdepth 1 -type d -name 'exosuit-*' -print -quit)
[[ -n "$install_dir" ]]

while IFS= read -r -d '' binary; do
	if readelf -d "$binary" | grep -E '(RPATH|RUNPATH)' | grep -E "$root_dir|/home/|/media/"; then
		echo "release artifact contains a source-tree runtime search path: $binary" >&2
		exit 1
	fi
done < <(find "$install_dir/lib" "$install_dir/tools" -type f \( -name '*.so*' -o -name '*.hdll' -o -name hl \) -print0)

portable="$fixture/portable state"
(
	cd "$fixture"
	PRAGTICAL_PORTABLE="$portable" xvfb-run -a "$install_dir/exosuit" --capture-dir="$fixture/capture" --smoke-frames=3
)
[[ -d "$portable" ]]
[[ -s "$fixture/capture/frame.png" ]]
[[ -s "$fixture/capture/app-state.json" ]]
echo "PASS: unpacked graphical artifact launched outside the source tree"

HAXEON_LSP="$install_dir/tools/haxeon-lsp" "$root_dir/scripts/test-haxeon-lsp.sh"
echo "PASS: unpacked artifact completed the real Haxeon language-service route"
