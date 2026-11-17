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
# hl is one file: libhl and the Haxeon runtime are compiled into it.
hashlink_dir=$("$haxeon_root/scripts/hashlink-path.sh")
cp "$hashlink_dir/hl" "$stage/tools/"
cp "$root_dir/graphical/build/host/native/pluginhost/libexosuit_plugin_host.so" "$stage/lib/"
cp -a "$root_dir/graphical/build/host/native/exosuit-ui-native/"*.so* "$stage/lib/"
cp "$root_dir/agent/build/host/main.hl" "$stage/tools/exosuit-agent.hl"
cp "$root_dir/agent/build/terminal-host/host/main.hl" "$stage/tools/exosuit-terminal-host.hl"
cp -a "$root_dir/agent/build/host/native/terminalkit/"*.so* "$stage/lib/"
cp "$root_dir/agent/build/host/native/sqlitekit/libsqlitekit.so" "$stage/lib/"
cp "$root_dir/scripts/run-codex-proxy.py" "$stage/tools/"
python3 "$root_dir/scripts/prepare_agent_naming.py"
mkdir -p "$stage/tools/claude-naming/node_modules/@anthropic-ai"
cp "$root_dir/agent/naming/claude-session-names.mjs" "$stage/tools/claude-naming/"
cp -R "$root_dir/agent/naming/node_modules/@anthropic-ai/claude-agent-sdk" "$stage/tools/claude-naming/node_modules/@anthropic-ai/"
cp "$root_dir/packaging/exosuit-agent" "$stage/tools/"
# Relocate only staged binaries; source build output retains its build paths.
patchelf --set-rpath '$ORIGIN/../lib' "$stage/tools/hl"
for library in "$stage/lib/"*.so*; do
	[[ -L "$library" ]] || patchelf --set-rpath '$ORIGIN' "$library"
done
# The language server is Haxeon's LspMain, built once into the checkout's tool cache (`haxeon lsp` runs the same file).
cp "$("$haxeon_root/scripts/haxeon" dev tool-path LspMain)" "$stage/tools/haxeon-lsp.hl"
cp -R "$haxeon_root/stdlib/." "$stage/stdlib/"
cp "$root_dir/packaging/haxeon-lsp" "$stage/tools/"
cp "$root_dir/packaging/exosuit" "$stage/exosuit"
