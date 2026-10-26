#!/usr/bin/env bash
# Thin wrapper around the haxeon CLI: builds and runs the headless test suite.
#
# The core project (haxeon.json) and each tests/<name>/haxeon.json project are
# built and launched with `haxeon build`/`haxeon run`. Fixture setup for tests
# that need files on disk lives here, matching what each project test entry
# expects on Sys.args().
set -euo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
haxeon_root=${HAXEON_ROOT:-"$root_dir/haxeon"}
haxeon=${HAXEON_BIN:-"$haxeon_root/scripts/haxeon"}
cc=${CC:-cc}

# Match build/run and the Haxeon CLI; both compiler modes are verified.
self_hosted=()
if [[ "${HAXEON_SELF_HOSTED:-0}" == "1" ]]; then
	self_hosted+=(--self-hosted)
fi

# Each test step runs whatever happened before it: a failure is reported, recorded and listed at the end, so one
# broken test cannot hide the ones after it. Fixture setup stays fail-fast (set -e), since later steps depend on it.
failures=()
steps=0
check() {
	local name=$1 status=0
	shift
	echo "== $name =="
	steps=$((steps + 1))
	"$@" || status=$?
	if ((status != 0)); then
		echo "FAIL: $name (exit $status)"
		failures+=("$name")
	fi
}

run_test() {
	local name=$1
	shift
	check "$name" "$haxeon" run --project "$root_dir/tests/$name/haxeon.json" "${self_hosted[@]}" -- "$@"
}

mkdir -p "$root_dir/build"

check plugin-host-bindings "$root_dir/scripts/update-plugin-host-bindings.sh" --check

check sqlite-native "$root_dir/native-packages/sqlite/tests/run.sh"
check terminal-native "$root_dir/native-packages/terminal/tests/run.sh"
check terminal-session-native "$root_dir/native-packages/terminal/session/tests/run.sh"
check noise-native "$root_dir/native-packages/noise/tests/run.sh"
terminal_native_dir="$root_dir/native-packages/terminal/session/tests/build/nativekit"
if [[ $(uname -s) == Darwin ]]; then
	export DYLD_LIBRARY_PATH="$terminal_native_dir${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
else
	export LD_LIBRARY_PATH="$terminal_native_dir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi

"$cc" -std=c11 -Wall -Wextra -Werror \
	"$root_dir/tests/process_fixture.c" \
	-o "$root_dir/build/process-fixture"

# The core entry checks shared document editing without a simulated native host.
check core "$haxeon" run --project "$root_dir/haxeon.json" "${self_hosted[@]}"

run_test plugin-host
run_test command-clipboard
run_test haxeon-rpc
run_test scm-git
run_test scm-watch
check workspace-transport bash "$root_dir/scripts/test-workspace-transport.sh"
check workspace-scm python3 "$root_dir/scripts/test-workspace-scm.py"
check relay bash "$root_dir/scripts/test-relay.sh"
check workspace-persistence bash "$root_dir/scripts/test-workspace-persistence.sh"
check workspace-attachment bash "$root_dir/scripts/test-workspace-attachment.sh"
check relay-setup python3 "$root_dir/scripts/test-relay-setup.py"
run_test workspace-lifecycle
check service-updates python3 "$root_dir/scripts/test-service-updates.py"
check agent-idle python3 "$root_dir/scripts/test-agent-idle.py"
check workspace-terminals python3 "$root_dir/scripts/test-workspace-terminals.py"
check workspace-agents python3 "$root_dir/scripts/test-workspace-agents.py"
check workspace-rpc-wasm bash "$root_dir/scripts/test-workspace-rpc-wasm.sh"
run_test application-test
run_test problems
capabilities_state=$(mktemp -d)
PRAGTICAL_PORTABLE="$capabilities_state" run_test host-capabilities-test
rm -rf "$capabilities_state"
run_test command-test
run_test editor-view-test
run_test tab-tooltip
run_test narrow-tabs
run_test status-bar
run_test sidebar-layout
run_test remote-access-panel
run_test browser-pairing-url

directory_scan_root=$(mktemp -d)
mkdir "$directory_scan_root/blocked" "$directory_scan_root/vanishing"
touch "$directory_scan_root/a.txt"
chmod 000 "$directory_scan_root/blocked"
run_test directory-scan "$directory_scan_root"
chmod 700 "$directory_scan_root/blocked"
rm -rf "$directory_scan_root"

mkdir -p "$root_dir/build/process cwd"
run_test process-test "$root_dir/build/process-fixture" "$root_dir/build/process cwd"

run_test json-rpc-transport-test "$root_dir/tests/fake_lsp.py"

language_project="$root_dir/build/language-service-project"
mkdir -p "$language_project"
run_test language-service-test "$root_dir/tests/fake_lsp.py" "$language_project"
run_test language-controller-test "$root_dir/tests/fake_lsp.py" "$language_project"

configuration_root="$root_dir/build/configuration-test"
configuration_project="$configuration_root/project"
mkdir -p "$configuration_project"
printf '{}' >"$configuration_root/user.json"
printf '{}' >"$configuration_root/project.json"
run_test configuration-test "$configuration_root/user.json" "$configuration_root/project.json" "$configuration_project" "$configuration_root/user.json"

printf 'saved by Haxeon\n' >"$root_dir/build/document-save-smoke.txt"
chmod 640 "$root_dir/build/document-save-smoke.txt"
run_test document-test "$root_dir/build/document-save-smoke.txt"
check document-save-mode test "$(stat -c '%a' "$root_dir/build/document-save-smoke.txt")" = 640

run_test plugin-test "$root_dir/build/process-fixture"

workspace_root="$root_dir/build/workspace-test"
workspace_other="$root_dir/build/workspace-test-other"
mkdir -p "$workspace_root/src" "$workspace_root/.git" "$workspace_root/.cache" "$workspace_root/.pragtical" "$workspace_other"
rm -f "$workspace_root/created.txt" "$workspace_root/moved.txt" "$workspace_root/replacement-backup.conf" "$workspace_root-replacement-backup.conf"
rm -f "$workspace_root-session-recovery.conf"
if [[ -d "$workspace_root-trash" ]]; then
	find "$workspace_root-trash" -mindepth 1 -delete
	rmdir "$workspace_root-trash"
fi
printf 'alpha\n' >"$workspace_root/alpha.txt"
printf 'class Main {\n  value;\n}\n' >"$workspace_root/src/Main.hx"
printf 'task=editor-test\nexecutable=%s\nargument=diagnostic\nargument=src/Main.hx\ncwd=.\n' "$root_dir/build/process-fixture" >"$workspace_root/.pragtical/tasks.conf"
printf '\0needle in binary\n' >"$workspace_root/binary.dat"
dd if=/dev/zero of="$workspace_root/oversized.dat" bs=1048576 count=5 status=none
printf 'needle but unreadable\n' >"$workspace_root/unreadable.txt"
chmod 000 "$workspace_root/unreadable.txt"
trap 'chmod 600 "$workspace_root/unreadable.txt" 2>/dev/null || true' EXIT
printf 'ignored\n' >"$workspace_root/.git/ignored"
printf 'ignored\n' >"$workspace_root/.cache/ignored"
printf 'needle in second project\n' >"$workspace_other/second.txt"
run_test workspace-test "$workspace_root" "$workspace_other"
run_test file-deletion "$root_dir/build/file-deletion-test"
saved_workspace_fixture=$(mktemp -d)
PRAGTICAL_PORTABLE="$saved_workspace_fixture/state" run_test saved-workspace "$saved_workspace_fixture/roots"
run_test project-scan-yield
chmod 600 "$workspace_root/unreadable.txt"

# Source compilation, compatible patches, structural reloads and failure rollback are mandatory.
dynamic_plugin_dir="$root_dir/build/dynamic-plugin"
mkdir -p "$dynamic_plugin_dir"
cp "$root_dir/plugins/example/plugin.conf" "$root_dir/plugins/example/Main.hx" "$dynamic_plugin_dir/"
run_test dynamic-plugin-test "$dynamic_plugin_dir/plugin.conf" "$dynamic_plugin_dir/Main.hx"

if ((${#failures[@]} > 0)); then
	echo "FAIL: ${#failures[@]} of $steps exosuit test steps failed: ${failures[*]}"
	exit 1
fi
echo "PASS: exosuit headless test suite ($steps steps)"
