#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
haxeon_root=${HAXEON_ROOT:-"$root_dir/../realtime-haxe"}
fixture=$(mktemp -d)
trap 'find "$fixture" -depth -delete' EXIT
document="$fixture/日本語-😀.txt"
expected="$fixture/expected.txt"
printf 'initial\n' > "$document"
printf 'Olá 日本語 😀 Z' > "$expected"

"$root_dir/scripts/build-sdl.sh"
xvfb-run -a bash -c '
	set -euo pipefail
	export LD_LIBRARY_PATH="$1/vendor/hashlink${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
	cd "$2/out"
	./pragtical-haxeon --smoke-seconds=5 "$3" &
	pid=$!
	window=""
	for _ in $(seq 1 100); do
		window=$(xdotool search --pid "$pid" 2>/dev/null | head -1 || true)
		[[ -n "$window" ]] && break
		sleep 0.02
	done
	[[ -n "$window" ]]
	printf "Olá 日本語 😀 Z" | xclip -selection clipboard
	xdotool windowfocus --sync "$window"
	xdotool windowsize "$window" 1120 720
	xdotool key --window "$window" ctrl+a ctrl+v
	xdotool key --window "$window" shift+Left ctrl+c
	[[ $(xclip -selection clipboard -o) == Z ]]
	xdotool key --window "$window" Right ctrl+alt+Left ctrl+s
	wait "$pid"
' bash "$haxeon_root" "$root_dir" "$document"
cmp "$expected" "$document"
