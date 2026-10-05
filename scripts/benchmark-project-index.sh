#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
haxeon_root=${HAXEON_ROOT:-"$repo_root/haxeon"}
fixture=$(mktemp -d)
trap 'find "$fixture" -type f -delete; find "$fixture" -depth -type d -empty -delete' EXIT

for directory in $(seq 0 99); do
	mkdir "$fixture/directory-$directory"
	for file in $(seq 0 99); do
		: > "$fixture/directory-$directory/file-$file.txt"
	done
done
ln -s "$fixture" "$fixture/directory-0/cycle"

haxeon=${HAXEON_BIN:-"$haxeon_root/scripts/haxeon"}
"$haxeon" run --project "$repo_root/tests/project-index-benchmark/haxeon.json" -- "$fixture" 10000
