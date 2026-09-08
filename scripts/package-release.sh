#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
haxeon_root=${HAXEON_ROOT:-"$root_dir/../realtime-haxe"}
pragtical_root=${PRAGTICAL_ROOT:-"$root_dir/../pragtical"}
platform=linux-x86_64
lock="$root_dir/release.lock"

locked_revision() {
	local name=$1
	sed -n "s/^$name=//p" "$lock"
}

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
verify_revision pragtical "$pragtical_root"
verify_revision hashlink "$haxeon_root/vendor/hashlink"

if [[ -n $(git -C "$haxeon_root" status --porcelain -- src stdlib native haxeon-lsp.hxml scripts/build-runtime.sh) ]]; then
	echo "Haxeon release inputs differ from the locked revision" >&2
	exit 1
fi
if [[ -n $(git -C "$pragtical_root" status --porcelain -- src/renderer data/fonts LICENSE licenses) ]]; then
	echo "Pragtical renderer release inputs differ from the locked revision" >&2
	exit 1
fi
if [[ -n $(git -C "$haxeon_root/vendor/hashlink" status --porcelain) ]]; then
	echo "HashLink release inputs differ from the locked revision" >&2
	exit 1
fi

"$haxeon_root/scripts/build-runtime.sh" >&2
"$haxeon_root/.tools/haxe/haxe" --cwd "$haxeon_root" "$haxeon_root/haxeon-lsp.hxml" >&2
"$root_dir/scripts/build-sdl.sh" >&2

short_revision=$(git -C "$root_dir" rev-parse --short=12 HEAD)
name="pragtical-haxeon-$short_revision-$platform"
stage_parent=$(mktemp -d "$root_dir/out/.package.XXXXXX")
stage="$stage_parent/$name"
trap 'find "$stage_parent" -depth -delete' EXIT
mkdir -p "$stage/tools" "$stage/data/fonts" "$stage/defaults" "$stage/docs" "$stage/licenses" "$stage/stdlib"

cp "$root_dir/out/pragtical-haxeon" "$root_dir/out/pragtical-haxeon.hl" \
	"$root_dir/out/pragtical_hx.hdll" "$root_dir/out/realtime_runtime.hdll" "$stage/"
cp "$haxeon_root/vendor/hashlink/hl" "$haxeon_root/vendor/hashlink/libhl.so" "$stage/tools/"
cp "$haxeon_root/out/haxeon-lsp.hl" "$stage/tools/"
cp -R "$haxeon_root/stdlib/." "$stage/stdlib/"
cp "$root_dir/packaging/haxeon-lsp" "$stage/tools/"
cp "$root_dir/out/data/fonts/JetBrainsMono-Regular.ttf" "$root_dir/out/data/fonts/NotoSansSymbols2-Regular.ttf" "$stage/data/fonts/"
cp "$root_dir/packaging/settings.conf" "$stage/defaults/settings.conf"
cp "$root_dir/packaging/README.md" "$stage/README.md"
cp "$root_dir/docs/getting-started.md" "$root_dir/docs/configuration.md" "$root_dir/docs/recovery.md" \
	"$root_dir/docs/build-tasks.md" "$root_dir/docs/plugin-api.md" "$root_dir/docs/plugin-development.md" \
	"$root_dir/docs/release-qualification.md" "$stage/docs/"
cp "$pragtical_root/LICENSE" "$stage/licenses/Pragtical-LICENSE"
cp "$pragtical_root/licenses/licenses.md" "$stage/licenses/Pragtical-third-party.md"
cp "$haxeon_root/vendor/hashlink/LICENSE" "$stage/licenses/HashLink-LICENSE"
cp "$haxeon_root/stdlib/LICENSE" "$stage/licenses/Haxe-stdlib-LICENSE"
printf '%s\n' \
	"pragtical-haxeon=$(git -C "$root_dir" rev-parse HEAD)" \
	"haxeon=$(locked_revision haxeon)" \
	"pragtical=$(locked_revision pragtical)" \
	"hashlink=$(locked_revision hashlink)" > "$stage/REVISIONS"

mkdir -p "$root_dir/dist"
archive="$root_dir/dist/$name.tar.gz"
tar -C "$stage_parent" -czf "$archive" "$name"
echo "$archive"
