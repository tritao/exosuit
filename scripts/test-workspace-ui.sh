#!/usr/bin/env bash
set -euo pipefail
root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
haxeon_root=${HAXEON_ROOT:-"$root_dir/../haxeon"}
fixture=$(mktemp -d)
cleanup() {
    if [[ -n ${WORKSPACE_UI_ARTIFACTS:-} ]]; then
        mkdir -p "$WORKSPACE_UI_ARTIFACTS"
        cp -R "$fixture/." "$WORKSPACE_UI_ARTIFACTS/"
    fi
    rm -rf -- "$fixture"
}
trap cleanup EXIT
compiler_mode=()
if [[ ${HAXEON_SELF_HOSTED:-0} == 1 ]]; then compiler_mode+=(--self-hosted); fi
mkdir -p "$fixture/project" "$fixture/state-restart"
printf 'class Main { static function main():Int { return 42; } }\n' > "$fixture/project/Main.hx"
project="$root_dir/tests/workspace-ui-smoke/haxeon.json"
"$haxeon_root/scripts/haxeon" build --project "$project" "${compiler_mode[@]}"
run_phase() {
    PRAGTICAL_PORTABLE="$fixture/state-$2" xvfb-run -a \
        "$haxeon_root/scripts/haxeon" run --project "$project" "${compiler_mode[@]}" \
        -- "${3:-$fixture/project/Main.hx}" "$fixture/$1" "$1"
}
# Distinct host processes exercise actual shutdown persistence and startup recovery.
run_phase write restart
test -s "$fixture/state-restart/session.conf"
test -s "$fixture/state-restart/recovery.conf"
run_phase read restart
run_phase keyboard keyboard
mkdir -p "$fixture/state-legacy" "$fixture/state-corrupt" "$fixture/state-invalid-dock"
printf 'version=3\nlayout=T\t\t0\t0\t0\t0\t0\tP\t%s\nlayout=T\t\t1\t0\t3\t0\t0\tP\t%s\n' \
    "$fixture/project/deleted.hx" "$fixture/project/Main.hx" > "$fixture/state-legacy/session.conf"
printf 'version=999\ninvalid session\n' > "$fixture/state-corrupt/session.conf"
printf 'version=3\nlayout=P\teditor\nlayout=D\tdock\t1\t{broken\nlayout=V\teditor\t1\t0\t3\t0\t0\tP\t%s\n' \
    "$fixture/project/Main.hx" > "$fixture/state-invalid-dock/session.conf"
for phase in legacy corrupt missing invalid-dock; do run_phase "$phase" "$phase"; done

mkdir -p "$fixture/sidebar-project" "$fixture/state-sidebar" "$fixture/state-sidebar-search"
python3 - "$fixture/sidebar-project/Main.hx" <<'PYFIXTURE'
import sys
with open(sys.argv[1], "w") as source:
    source.write("needle match\n" * 100)
from pathlib import Path
for index in range(24):
    Path(sys.argv[1]).with_name(f"tree-row-{index:02d}.txt").write_text("")
PYFIXTURE
run_phase sidebar-write sidebar "$fixture/sidebar-project/Main.hx"
run_phase sidebar-read sidebar "$fixture/sidebar-project/Main.hx"
run_phase sidebar-hidden-read sidebar "$fixture/sidebar-project/Main.hx"
run_phase sidebar-search sidebar-search "$fixture/sidebar-project/Main.hx"
run_phase sidebar-preview sidebar-preview "$fixture/sidebar-project/Main.hx"
run_phase sidebar-stale-preview sidebar-stale-preview "$fixture/sidebar-project/Main.hx"

run_phase editor-scroll editor-scroll "$fixture/sidebar-project/Main.hx"
run_phase scrollbar-visibility scrollbar-visibility "$fixture/sidebar-project/Main.hx"
run_phase editor-resize editor-resize "$fixture/sidebar-project/Main.hx"
run_phase editor-minimap editor-minimap "$fixture/sidebar-project/Main.hx"
run_phase settings settings "$fixture/sidebar-project/Main.hx"
mkdir -p "$fixture/tab-project"
for name in Main.hx NativeDesktopPlatform.hx Platform.hx README.md a-very-long-Unicode-🙂-filename-that-needs-an-ellipsis.hx Last.hx; do
    printf 'tab fixture\n' > "$fixture/tab-project/$name"
done
run_phase editor-tabs editor-tabs "$fixture/tab-project/Main.hx"

printf 'old\n' > "$fixture/sidebar-project/Other.hx"
mkdir -p "$fixture/state-language-folder"
python3 - "$fixture/state-language-folder/settings.json" "$root_dir/tests/fake_lsp.py" "$fixture/language-events.jsonl" <<'PYLANG'
import json, sys
with open(sys.argv[1], "w") as settings:
    json.dump({"version": 1, "values": {"languages/haxeon/command": json.dumps(["python3", sys.argv[2], "--events", sys.argv[3]])}, "state": {}}, settings)
PYLANG
run_phase language-folder language-folder "$fixture/sidebar-project/Main.hx"

mkdir -p "$fixture/explorer-project/folder"
printf 'a\n' > "$fixture/explorer-project/folder/A.txt"
printf 'b\n' > "$fixture/explorer-project/folder/B.txt"
printf 'c\n' > "$fixture/explorer-project/folder/C.txt"
run_phase explorer-preview explorer-preview "$fixture/explorer-project/Main.hx"

printf 'class Main {}\n' > "$fixture/explorer-project/Main.hx"
printf '{}\n' > "$fixture/explorer-project/data.json"
printf '# Readme\n' > "$fixture/explorer-project/README.md"
printf 'print(1)\n' > "$fixture/explorer-project/tool.py"
printf 'fallback\n' > "$fixture/explorer-project/mystery.wibble"
printf '# Notes\n' > "$fixture/explorer-project/notes.md"
printf 'FROM scratch\n' > "$fixture/explorer-project/Dockerfile"
printf 'long filename\n' > "$fixture/explorer-project/language-controller-test-with-an-extra-long-filename.hl"
run_phase explorer-icons explorer-icons "$fixture/explorer-project/Main.hx"
