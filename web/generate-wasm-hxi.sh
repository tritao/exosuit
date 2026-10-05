#!/usr/bin/env bash
# Generates the wasm32 (portable-abi32) Haxe FFI interfaces the browser build
# compiles against, into OUTPUT_DIR.
#
# Each kit already owns a script that audits its C import header and writes the
# desktop (portable-abi64) interface. Rather than duplicating their header,
# include and dependency lists, this runs those scripts against a shim
# haxeon-ffi-audit that swaps the desktop targets for the Emscripten/WASI
# targets and points dependency interfaces at the wasm32 copies written here.
set -euo pipefail

if [[ $# -lt 2 ]]; then
	echo "usage: tools/web/generate-wasm-hxi.sh OUTPUT_DIR SCRIPT:NAME[:OUTPUT_PREFIX] ..." >&2
	exit 2
fi

materia_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
haxeon_dir=${HAXEON_DIR:-"$materia_dir/exosuit/haxeon"}
mkdir -p "$1"
output_dir=$(cd "$1" && pwd)
shim_dir=$(mktemp -d)
trap 'rm -rf -- "${shim_dir:?}"' EXIT

mkdir -p "$shim_dir/scripts"
# Vendored package audit scripts resolve headers and projections below HAXEON_DIR.
ln -s "$haxeon_dir/packages" "$shim_dir/packages"
ln -s "$haxeon_dir/vendor" "$shim_dir/vendor"
cat > "$shim_dir/scripts/haxeon-ffi-audit" <<SHIM
#!/usr/bin/env bash
set -euo pipefail
arguments=(--target=wasm32-unknown-wasi --target=wasm32-unknown-emscripten --profile=portable-abi32)
for argument in "\$@"; do
	case \$argument in
		--target=* | --profile=*) ;;
		--dependency-hxi=*.hxi)
			arguments+=("--dependency-hxi=$output_dir/\$(basename "\${argument#--dependency-hxi=}")") ;;
		*) arguments+=("\$argument") ;;
	esac
done
exec "$haxeon_dir/scripts/haxeon-ffi-audit" "\${arguments[@]}"
SHIM
chmod +x "$shim_dir/scripts/haxeon-ffi-audit"

# Callers list generators in dependency order; each toolkit keeps ownership
# of its header, include paths and audit rules.
shift
for generator in "$@"; do
	IFS=: read -r script name prefix <<<"$generator"
	[[ -n "$script" && -n "$name" ]]
	(cd "$materia_dir/$(dirname "$(dirname "$script")")" &&
		HAXEON_DIR="$shim_dir" bash "$materia_dir/$script" "${prefix:-}$output_dir/$name") >/dev/null
	echo "generate-wasm-hxi: $name"
done
