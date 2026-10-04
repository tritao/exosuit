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
        -- "$fixture/project/Main.hx" "$fixture/$1" "$1"
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
