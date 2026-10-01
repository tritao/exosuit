#!/usr/bin/env bash
# Opens the built browser editor in headless Chrome and checks that it starts and draws.
#   web/test.sh [--screenshot PATH] [--frames N]
set -euo pipefail

app_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
site_dir=${EXOSUIT_WEB_SITE_DIR:-"$app_dir/build/web/site"}
browser=${EXOSUIT_WEB_BROWSER:-}
if [[ ! -f "$site_dir/index.html" ]]; then
	echo "test.sh: $site_dir has no build; run web/build.sh" >&2
	exit 1
fi
if [[ -z "$browser" ]]; then
	for candidate in google-chrome chromium chromium-browser; do
		if command -v "$candidate" >/dev/null 2>&1; then
			browser=$(command -v "$candidate")
			break
		fi
	done
fi
[[ -n "$browser" ]] || { echo "test.sh: no Chrome found; set EXOSUIT_WEB_BROWSER" >&2; exit 1; }

free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'; }
http_port=$(free_port)
debug_port=$(free_port)
temp_dir=$(mktemp -d)
cleanup() {
	if [[ -n ${browser_pid:-} ]]; then
		kill -- "-$browser_pid" 2>/dev/null || true
	fi
	kill "${http_pid:-}" 2>/dev/null || true
	wait "${browser_pid:-}" "${http_pid:-}" 2>/dev/null || true
	rm -rf -- "${temp_dir:?}"
}
trap cleanup EXIT

python3 -m http.server "$http_port" --bind 127.0.0.1 --directory "$site_dir" >"$temp_dir/http.log" 2>&1 &
http_pid=$!
page_url="http://127.0.0.1:$http_port/index.html"
setsid "$browser" --headless=new --no-sandbox --disable-dev-shm-usage --enable-unsafe-swiftshader --use-angle=swiftshader \
	--disable-background-timer-throttling --disable-renderer-backgrounding --disable-backgrounding-occluded-windows \
	--window-size=1400,900 --no-first-run --user-data-dir="$temp_dir/profile" \
	--remote-debugging-port="$debug_port" --remote-allow-origins='*' "$page_url" >"$temp_dir/browser.log" 2>&1 &
browser_pid=$!
python3 "$app_dir/web/tools/smoke.py" --debug-port "$debug_port" --page-url "$page_url" "$@"
