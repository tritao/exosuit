#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
haxeon_root=${HAXEON_ROOT:-"$root_dir/../haxeon"}
materia_root=$(cd "$root_dir/.." && pwd)
lock="$root_dir/release.lock"
[[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || { echo "Release packaging currently supports Linux x86-64" >&2; exit 1; }

locked_revision() { sed -n "s/^$1=//p" "$lock"; }
verify_revision() {
	local name=$1 directory=$2 expected actual
	expected=$(locked_revision "$name")
	actual=$(git -C "$directory" rev-parse HEAD)
	if [[ -z "$expected" || "$actual" != "$expected" ]]; then
		echo "$name revision mismatch: expected $expected, found $actual" >&2
		exit 1
	fi
}
verify_revision haxeon "$haxeon_root"
verify_revision materia "$materia_root"
verify_revision nativekit "$materia_root/nativekit"
verify_revision hashlink "$haxeon_root/vendor/hashlink"
for spec in "$haxeon_root:src stdlib native embed CMakeLists.txt scripts" "$materia_root:uikit editorkit" "$materia_root/nativekit:." "$haxeon_root/vendor/hashlink:."; do
	directory=${spec%%:*}
	read -r -a paths <<< "${spec#*:}"
	if [[ -n $(git -C "$directory" status --porcelain -- "${paths[@]}") ]]; then
		echo "Release inputs differ from the locked revision: $directory" >&2
		exit 1
	fi
done
# CMake builds both the VM and runtime from vendor/hashlink, regardless of
# historical checkout metadata left in the .tools output directory.
(cd "$haxeon_root" && ./scripts/build-native.sh) >&2
"$haxeon_root/.tools/haxe/haxe" --cwd "$haxeon_root" "$haxeon_root/haxeon-lsp.hxml" >&2
"$root_dir/scripts/build.sh" >&2

short_revision=$(git -C "$root_dir" rev-parse --short=12 HEAD)
name="exosuit-$short_revision-linux-x86_64"
mkdir -p "$root_dir/out" "$root_dir/dist"
stage_parent=$(mktemp -d "$root_dir/out/.package.XXXXXX")
stage="$stage_parent/$name"
trap 'rm -rf "$stage_parent"' EXIT
mkdir -p "$stage/tools" "$stage/lib" "$stage/defaults" "$stage/docs" "$stage/licenses" "$stage/stdlib"
cp "$root_dir/graphical/build/host/main.hl" "$stage/exosuit.hl"
cp "$haxeon_root/.tools/hashlink/hl" "$stage/tools/"
cp -L "$haxeon_root/.tools/hashlink/libhl.so" "$stage/lib/libhl.so.1"
ln -s libhl.so.1 "$stage/lib/libhl.so"
cp "$haxeon_root/out/haxeon_runtime.hdll" "$stage/lib/"
cp "$root_dir/graphical/build/host/native/pragtical_hx/libpragtical_hx.so" "$stage/lib/"
cp -a "$root_dir/graphical/build/host/native/exosuit-ui-native/"*.so* "$stage/lib/"
# Relocate only staged binaries; source build output retains its build paths.
patchelf --set-rpath '$ORIGIN/../lib' "$stage/tools/hl"
for library in "$stage/lib/"*.so* "$stage/lib/"*.hdll; do
	[[ -L "$library" ]] || patchelf --set-rpath '$ORIGIN' "$library"
done
cp "$haxeon_root/out/haxeon-lsp.hl" "$stage/tools/"
cp -R "$haxeon_root/stdlib/." "$stage/stdlib/"
cp "$root_dir/packaging/haxeon-lsp" "$stage/tools/"
cp "$root_dir/packaging/exosuit" "$stage/exosuit"
cp "$root_dir/packaging/settings.conf" "$stage/defaults/"
cp "$root_dir/packaging/README.md" "$stage/README.md"
cp "$root_dir/docs/"*.md "$stage/docs/"
cp "$materia_root/nativekit/LICENSE" "$stage/licenses/NativeKit-LICENSE"
cp "$haxeon_root/vendor/hashlink/LICENSE" "$stage/licenses/HashLink-LICENSE"
cp "$haxeon_root/stdlib/LICENSE" "$stage/licenses/Haxe-stdlib-LICENSE"
mkdir -p "$stage/licenses/seti"
cp "$root_dir/graphical/assets/seti/LICENSE.txt" "$root_dir/graphical/assets/seti/ThirdPartyNotices.txt" "$root_dir/graphical/assets/seti/SOURCE.txt" "$stage/licenses/seti/"
# Preserve native dependency notices with their original names and hierarchy.
for toolkit in nativekit uikit; do
	while IFS= read -r -d '' notice; do
		relative=${notice#"$materia_root/"}
		mkdir -p "$stage/licenses/$(dirname "$relative")"
		cp "$notice" "$stage/licenses/$relative"
	done < <(find "$materia_root/$toolkit/vendor" -type f -iname '*license*' -print0)
done
printf 'exosuit=%s\n' "$(git -C "$root_dir" rev-parse HEAD)" > "$stage/REVISIONS"
cat "$lock" >> "$stage/REVISIONS"
archive="$root_dir/dist/$name.tar.gz"
tar -C "$stage_parent" -czf "$archive" "$name"
echo "$archive"
