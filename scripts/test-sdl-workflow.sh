#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
haxeon_root=${HAXEON_ROOT:-"$root_dir/../realtime-haxe"}
fixture=$(mktemp -d)
trap 'find "$fixture" -depth -delete' EXIT
project="$fixture/project"
plugin="$fixture/plugin"
mkdir -p "$project" "$plugin"
printf 'initial\n' > "$project/first.txt"
printf 'secondneedle\n' > "$project/second.txt"
cp "$root_dir/plugins/example/plugin.conf" "$root_dir/plugins/example/Main.hx" "$plugin/"

"$root_dir/scripts/build-sdl.sh"
xvfb-run -a bash -c '
	set -euo pipefail
	export LD_LIBRARY_PATH="$1/vendor/hashlink${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
	cd "$2/out"
	./pragtical-haxeon --smoke-seconds=30 --plugin="$4/plugin.conf" "$3" &
	pid=$!
	window=""
	for _ in $(seq 1 100); do
		window=$(xdotool search --onlyvisible --pid "$pid" 2>/dev/null | head -1 || true)
		[[ -n "$window" ]] && break
		sleep 0.02
	done
	[[ -n "$window" ]]
	xdotool windowfocus --sync "$window"
	sleep 0.2
	xdotool key --window "$window" ctrl+p
	xdotool type --window "$window" --delay 2 first.txt
	xdotool key --window "$window" Return
	sleep 0.2
	xdotool key --window "$window" ctrl+a
	xdotool type --window "$window" --delay 2 "projectneedle alpha"
	xdotool key --window "$window" shift+Left ctrl+z ctrl+y ctrl+s
	sleep 0.2
	xdotool key --window "$window" ctrl+shift+p
	xdotool type --window "$window" --delay 2 splitright
	xdotool key --window "$window" Return
	sleep 0.2
	xdotool key --window "$window" ctrl+p
	xdotool type --window "$window" --delay 2 second.txt
	xdotool key --window "$window" Return
	sleep 0.2
	xdotool key --window "$window" ctrl+Tab ctrl+f
	xdotool type --window "$window" --delay 2 projectneedle
	xdotool key --window "$window" Escape ctrl+h
	xdotool type --window "$window" --delay 2 replaced
	xdotool key --window "$window" Return ctrl+s
	sleep 0.2
	xdotool key --window "$window" ctrl+shift+f
	xdotool type --window "$window" --delay 2 secondneedle
	sleep 0.3
	xdotool key --window "$window" Return
	sleep 0.2
	xdotool key --window "$window" ctrl+shift+p
	xdotool type --window "$window" --delay 2 pluginsreload
	xdotool key --window "$window" Return
	sleep 0.2
	xdotool key --window "$window" Return
	wait "$pid"
' bash "$haxeon_root" "$root_dir" "$project" "$plugin"

if [[ $(<"$project/first.txt") != "replaced alpha" ]]; then
	echo "graphical workflow produced unexpected first.txt: $(<"$project/first.txt")" >&2
	exit 1
fi
if [[ $(<"$project/second.txt") != secondneedle ]]; then
	echo "graphical workflow changed second.txt unexpectedly: $(<"$project/second.txt")" >&2
	exit 1
fi
echo "PASS: graphical keyboard workflow opened, edited, saved, split, searched, replaced, switched tabs, and reloaded a plugin"
