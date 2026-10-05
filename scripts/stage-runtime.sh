#!/usr/bin/env bash
# Stage already built runtime assets; release lock validation belongs to package-release.sh.
# Used by relocation acceptance without publishing an archive or altering release pins.
set -euo pipefail
root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
haxeon_root=${HAXEON_ROOT:-"$root_dir/haxeon"}
[[ $# == 1 ]] || { echo "Usage: stage-runtime.sh EMPTY_DIRECTORY" >&2; exit 1; }
mkdir -p "$1"
[[ -z $(ls -A "$1") ]] || { echo "Runtime stage must be empty" >&2; exit 1; }
stage=$(cd "$1" && pwd)
mkdir -p "$stage/tools" "$stage/lib" "$stage/stdlib"
cp "$root_dir/graphical/build/host/main.hl" "$stage/exosuit.hl"
cp "$haxeon_root/.tools/hashlink/hl" "$stage/tools/"
cp -L "$haxeon_root/.tools/hashlink/libhl.so" "$stage/lib/libhl.so.1"
ln -s libhl.so.1 "$stage/lib/libhl.so"
cp "$haxeon_root/out/haxeon_runtime.hdll" "$stage/lib/"
cp "$root_dir/graphical/build/host/native/hostservices/libpragtical_hx.so" "$stage/lib/"
cp -a "$root_dir/graphical/build/host/native/exosuit-ui-native/"*.so* "$stage/lib/"
cp "$root_dir/agent/build/host/main.hl" "$stage/tools/exosuit-agent.hl"
cp -a "$root_dir/agent/build/host/native/terminalkit/"*.so* "$stage/lib/"
cp "$root_dir/agent/build/host/native/sqlitekit/libsqlitekit.so" "$stage/lib/"
cp "$root_dir/scripts/run-agent.py" "$root_dir/scripts/run-codex-proxy.py" "$stage/tools/"
cp "$root_dir/packaging/exosuit-agent" "$stage/tools/"
# Relocate only staged binaries; source build output retains its build paths.
patchelf --set-rpath '$ORIGIN/../lib' "$stage/tools/hl"
for library in "$stage/lib/"*.so* "$stage/lib/"*.hdll; do
	[[ -L "$library" ]] || patchelf --set-rpath '$ORIGIN' "$library"
done
cp "$haxeon_root/out/haxeon-lsp.hl" "$stage/tools/"
cp -R "$haxeon_root/stdlib/." "$stage/stdlib/"
cp "$root_dir/packaging/haxeon-lsp" "$stage/tools/"
cp "$root_dir/packaging/exosuit" "$stage/exosuit"
