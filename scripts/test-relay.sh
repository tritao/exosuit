#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
relay_dir="$root_dir/relay/worker"

if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
	echo "Node.js and npm are required for relay tests" >&2
	exit 1
fi

(cd "$relay_dir" && npm ci --no-audit --no-fund && npm run check)
