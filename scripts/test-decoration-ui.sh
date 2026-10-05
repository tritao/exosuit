#!/usr/bin/env bash
set -euo pipefail
root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
haxeon_root=${HAXEON_ROOT:-"$root_dir/../haxeon"}
fixture=$(mktemp -d)
cleanup() {
    if [[ -n ${DECORATION_UI_ARTIFACTS:-} ]]; then
        mkdir -p "$DECORATION_UI_ARTIFACTS"
        cp -R "$fixture/." "$DECORATION_UI_ARTIFACTS/"
    fi
    rm -rf -- "$fixture"
}
trap cleanup EXIT
compiler_mode=()
if [[ ${HAXEON_SELF_HOSTED:-0} == 1 ]]; then
    compiler_mode+=(--self-hosted)
fi
mkdir -p "$fixture/project"
printf 'class Main { static function main():Int { return 42; } }\n' > "$fixture/project/Main.hx"
"$haxeon_root/scripts/haxeon" build --project "$root_dir/tests/decoration-ui-smoke/haxeon.json" "${compiler_mode[@]}"
for phase in ime-selection-affinity terminal-editor-transfer terminal-group-no-build terminal-group-no-tools terminal-group-migrate editor-header gutter-aligned selection-clipped pane-session-roundtrip pane-close-shared pane-close-cancel pane-close-discard pane-move-unique pane-move-duplicate pane-split-right pane-split-down pane-selection-model menu-capture menu-escape menu-outside menu-editor menu-tab menu-tab-keyboard menu-switch menu-tree menu-keyboard menu-tree-keyboard menu-predicate menu-stale menu-edge menu-dirty-close decorated moved cleared selection caret caret-moved caret-empty multi-selected multi-typed multi-pasted multi-navigation multi-wrapped syntax-open syntax-closed syntax-restored popup-hover popup-completion popup-live-completion popup-signature popup-edge popup-switch popup-large popup-scroll popup-clipped; do
    PRAGTICAL_PORTABLE="$fixture/state-$phase" xvfb-run -a \
        "$haxeon_root/scripts/haxeon" run --project "$root_dir/tests/decoration-ui-smoke/haxeon.json" "${compiler_mode[@]}" \
        -- "$fixture/project/Main.hx" "$fixture/$phase" "$phase"
done
python3 "$root_dir/scripts/check-decoration-pixels.py" "$fixture"
