#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
haxeon_root=${HAXEON_ROOT:-"$root_dir/haxeon"}
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
rss_file="$fixture/peak-rss.txt"
plugin_dir="$fixture/plugin"
mkdir "$plugin_dir"
cp "$root_dir/plugins/example/plugin.conf" "$root_dir/plugins/example/Main.hx" "$plugin_dir/"

haxeon=${HAXEON_BIN:-"$haxeon_root/scripts/haxeon"}
"$haxeon" build --project "$root_dir/tests/release-benchmark/haxeon.json"
/usr/bin/time -f 'BENCH peak_rss_kib=%M' -o "$rss_file" \
 "$haxeon" run --project "$root_dir/tests/release-benchmark/haxeon.json" -- \
 "$fixture" "$plugin_dir/plugin.conf" "$plugin_dir/Main.hx"
sed -n '1p' "$rss_file"
