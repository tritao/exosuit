#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
haxeon_root=${HAXEON_ROOT:-"$root_dir/../realtime-haxe"}

(
	cd "$haxeon_root"
	SKIP_FORMAT_CHECK=${SKIP_FORMAT_CHECK:-0} ./scripts/test.sh
)
(
	cd "$root_dir"
	SKIP_FORMAT_CHECK=${SKIP_FORMAT_CHECK:-0} ./scripts/test.sh
	./scripts/test-sdl-smoke.sh
	./scripts/test-sdl-input.sh
	./scripts/test-release.sh
)
