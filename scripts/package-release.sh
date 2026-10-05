#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
haxeon_root=${HAXEON_ROOT:-"$root_dir/haxeon"}
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
verify_revision nativekit "$haxeon_root/vendor/nativekit"
verify_revision hashlink "$haxeon_root/vendor/hashlink"
for spec in "$haxeon_root:src stdlib native embed packages CMakeLists.txt scripts" "$haxeon_root/vendor/nativekit:." "$haxeon_root/vendor/hashlink:."; do
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
python3 "$root_dir/scripts/build.py" >&2
"$haxeon_root/scripts/haxeon" build --project "$root_dir/agent/haxeon.json" >&2

short_revision=$(git -C "$root_dir" rev-parse --short=12 HEAD)
name="exosuit-$short_revision-linux-x86_64"
mkdir -p "$root_dir/out" "$root_dir/dist"
stage_parent=$(mktemp -d "$root_dir/out/.package.XXXXXX")
stage="$stage_parent/$name"
trap 'rm -rf "$stage_parent"' EXIT
"$root_dir/scripts/stage-runtime.sh" "$stage"
mkdir -p "$stage/defaults" "$stage/docs" "$stage/licenses"
cp "$root_dir/packaging/settings.json" "$stage/defaults/"
cp "$root_dir/packaging/README.md" "$stage/README.md"
cp "$root_dir/docs/"*.md "$stage/docs/"
cp "$haxeon_root/vendor/nativekit/LICENSE" "$stage/licenses/NativeKit-LICENSE"
cp "$haxeon_root/vendor/hashlink/LICENSE" "$stage/licenses/HashLink-LICENSE"
cp "$haxeon_root/stdlib/LICENSE" "$stage/licenses/Haxe-stdlib-LICENSE"
sed -n '31,42p' "$root_dir/native-packages/sqlite/vendor/sqlite3.c" > "$stage/licenses/SQLite-NOTICE"
mkdir -p "$stage/licenses/seti"
cp "$root_dir/graphical/assets/seti/LICENSE.txt" "$root_dir/graphical/assets/seti/ThirdPartyNotices.txt" "$root_dir/graphical/assets/seti/SOURCE.txt" "$stage/licenses/seti/"
# Preserve native dependency notices with their original names and hierarchy.
for toolkit in "$haxeon_root/vendor/nativekit" "$haxeon_root/packages/ui" "$root_dir/native-packages/terminal"; do
	while IFS= read -r -d '' notice; do
		relative=${notice#"$materia_root/"}
		mkdir -p "$stage/licenses/$(dirname "$relative")"
		cp "$notice" "$stage/licenses/$relative"
	done < <(find "$toolkit/vendor" -type f \( -iname '*license*' -o -iname 'copying*' \) -print0)
done
printf 'exosuit=%s\n' "$(git -C "$root_dir" rev-parse HEAD)" > "$stage/REVISIONS"
cat "$lock" >> "$stage/REVISIONS"
archive="$root_dir/dist/$name.tar.gz"
tar -C "$stage_parent" -czf "$archive" "$name"
echo "$archive"
