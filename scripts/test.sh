#!/usr/bin/env bash
# Builds and runs the headless test suites listed in tests/suites.txt (the rows for all and posix), in that order.
# `--list` prints them and runs nothing.
#
# Haxeon test projects are built and launched with `haxeon run`. Fixture setup for suites that need files on disk lives
# here (`fixture` below, named by the list's fixture column), matching what each test entry expects on Sys.args().
#
# On Windows run scripts/test-windows.ps1 instead: the suites and drivers that run there, each behind the dialog guard
# with state of its own (-List says what it leaves out and why).
set -euo pipefail
# Everything the tests start keeps its state in a home of the run's own, removed at the end: never the user's exohost
# (which is not started either, see exohost/README.md), editor or agent state, ~/.claude or ~/.codex. Variables inherited
# from the user's session are replaced, not reused. EXOSUIT_TEST_HOME names a folder to use instead (kept).
# macOS's default $TMPDIR (/var/folders/xx/<28 characters>/T/) is too long for the unix sockets the tests' state holds
# (sockaddr_un has 104 bytes).
if [[ $(uname -s) == Darwin ]]; then export TMPDIR=/tmp; fi
test_home=${EXOSUIT_TEST_HOME:-}
remove_test_home=0
if [[ -z $test_home ]]; then
	test_home=$(mktemp -d)
	remove_test_home=1
fi
export EXOSUIT_EXOHOST_HOME="$test_home/exohost" EXOSUIT_EXOHOST_AUTOSTART=0 PRAGTICAL_PORTABLE="$test_home/portable" 	EXOSUIT_AGENT_STATE_HOME="$test_home/agent-state" CLAUDE_CONFIG_DIR="$test_home/claude-config" CODEX_HOME="$test_home/codex-home"
mkdir -p "$EXOSUIT_EXOHOST_HOME" "$PRAGTICAL_PORTABLE" "$EXOSUIT_AGENT_STATE_HOME" "$CLAUDE_CONFIG_DIR" "$CODEX_HOME"
# Headless UI tests check, on every frame that did work, that the retained tree equals a fresh build and that no
# submitted node was edited in place without BuildContext.willEditRetained (UiContext.verifyRetentionEvery). 0 turns it off.
export HAXEON_UI_VERIFY_RETENTION=${HAXEON_UI_VERIFY_RETENTION:-1}

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

suites="$root_dir/tests/suites.txt"
# The rows of tests/suites.txt this runner runs, one per line: name on kind timeout fixture target arguments.
rows() {
	local line
	while IFS= read -r line; do
		line=${line%% # *}
		[[ -z ${line// /} || $line == \#* ]] && continue
		local on
		read -r _ on _ <<<"$line"
		[[ $on == all || $on == posix ]] && printf '%s\n' "$line"
	done <"$suites"
}

if [[ ${1:-} == --list ]]; then
	rows | while read -r name _ kind _ _ target arguments; do printf '%-26s %-7s %s\n' "$name" "$kind" "$target${arguments:+ $arguments}"; done
	exit 0
fi

mkdir -p "$root_dir/build"
fixtures=$(mktemp -d)
workspace_root="$root_dir/build/workspace-test"
cleanup() {
	chmod 600 "$workspace_root/unreadable.txt" 2>/dev/null || true
	chmod -R u+rwx "$fixtures" 2>/dev/null || true
	rm -rf "$fixtures"
	if ((remove_test_home)); then rm -rf "$test_home"; fi
}
trap cleanup EXIT

terminal_native_dir="$root_dir/native-packages/terminal/session/tests/build/nativekit"
if [[ $(uname -s) == Darwin ]]; then
	export DYLD_LIBRARY_PATH="$terminal_native_dir${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
else
	export LD_LIBRARY_PATH="$terminal_native_dir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi

"$cc" -std=c11 -Wall -Wextra -Werror \
	"$root_dir/tests/process_fixture.c" \
	-o "$root_dir/build/process-fixture"

# A suite's fixture (the fixture column of tests/suites.txt): makes its files, then sets `args`, the suite's arguments,
# and `step_env`, variables for that suite only.
fixture() {
	local name=$1 dir="$fixtures/$2"
	args=()
	step_env=()
	case $name in
	-) ;;
	portable)
		mkdir -p "$dir"
		step_env=(PRAGTICAL_PORTABLE="$dir")
		;;
	unreadable-folder)
		mkdir -p "$dir/blocked" "$dir/vanishing"
		touch "$dir/a.txt"
		chmod 000 "$dir/blocked"
		args=("$dir")
		;;
	process-cwd)
		mkdir -p "$root_dir/build/process cwd"
		args=("$root_dir/build/process-fixture" "$root_dir/build/process cwd")
		;;
	process-fixture) args=("$root_dir/build/process-fixture") ;;
	fake-lsp) args=("$root_dir/tests/fake_lsp.py") ;;
	fake-lsp-project)
		mkdir -p "$root_dir/build/language-service-project"
		args=("$root_dir/tests/fake_lsp.py" "$root_dir/build/language-service-project")
		;;
	configuration)
		local configuration_root="$root_dir/build/configuration-test"
		mkdir -p "$configuration_root/project"
		printf '{}' >"$configuration_root/user.json"
		printf '{}' >"$configuration_root/project.json"
		args=("$configuration_root/user.json" "$configuration_root/project.json" "$configuration_root/project" "$configuration_root/user.json")
		;;
	document)
		printf 'saved by Haxeon\n' >"$root_dir/build/document-save-smoke.txt"
		chmod 640 "$root_dir/build/document-save-smoke.txt"
		args=("$root_dir/build/document-save-smoke.txt")
		;;
	workspace)
		local workspace_other="$root_dir/build/workspace-test-other"
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
		printf 'ignored\n' >"$workspace_root/.git/ignored"
		printf 'ignored\n' >"$workspace_root/.cache/ignored"
		printf 'needle in second project\n' >"$workspace_other/second.txt"
		args=("$workspace_root" "$workspace_other")
		;;
	file-deletion) args=("$root_dir/build/file-deletion-test") ;;
	state-and-roots)
		step_env=(PRAGTICAL_PORTABLE="$dir/state")
		args=("$dir/roots")
		;;
	content-store)
		mkdir -p "$dir/content-store"
		args=("$dir/content-store")
		;;
	codex-history)
		mkdir -p "$dir/codex-history"
		args=("$dir/codex-history" python3 "$root_dir/scripts/run-codex-proxy.py" "$root_dir/tests/workspace-agents/fake-codex.py")
		;;
	dynamic-plugin)
		local plugin_dir="$root_dir/build/dynamic-plugin"
		mkdir -p "$plugin_dir"
		cp "$root_dir/plugins/example/plugin.conf" "$root_dir/plugins/example/Main.hx" "$plugin_dir/"
		args=("$plugin_dir/plugin.conf" "$plugin_dir/Main.hx")
		;;
	*)
		echo "test.sh: unknown fixture $name" >&2
		return 1
		;;
	esac
}

# The checks of kind `check`.
own_check() {
	case $1 in
	document-save-mode) test "$(python3 -c 'import os, stat, sys; print(format(stat.S_IMODE(os.stat(sys.argv[1]).st_mode), "o"))' "$root_dir/build/document-save-smoke.txt")" = 640 ;;
	*)
		echo "test.sh: unknown check $1" >&2
		return 1
		;;
	esac
}

# coreutils timeout; macOS has it as gtimeout (brew install coreutils), and scripts/timeout.py stands in without it.
timeout=$(command -v timeout || command -v gtimeout || true)
if [[ -z $timeout ]]; then
	timeout="$root_dir/scripts/timeout.py"
fi
# Each suite is stopped after its timeout (the list's column), and killed 10 s later if it is still running.
# File descriptor 3: a suite that reads its standard input must not read the list.
while read -r -u 3 name _ kind seconds fixture_name target arguments; do
	fixture "$fixture_name" "$name"
	read -ra extra <<<"$arguments"
	limit=("$timeout" --kill-after=10 "$seconds")
	case $kind in
	haxeon) check "$name" "${limit[@]}" env ${step_env[@]+"${step_env[@]}"} "$haxeon" run --project "$root_dir/$target" ${self_hosted[@]+"${self_hosted[@]}"} -- ${args[@]+"${args[@]}"} ;;
	python) check "$name" "${limit[@]}" env ${step_env[@]+"${step_env[@]}"} python3 "$root_dir/$target" ${extra[@]+"${extra[@]}"} ;;
	bash) check "$name" "${limit[@]}" env ${step_env[@]+"${step_env[@]}"} bash "$root_dir/$target" ${extra[@]+"${extra[@]}"} ;;
	check) check "$name" own_check "$name" ;;
	*)
		echo "test.sh: $name has an unknown kind $kind" >&2
		exit 2
		;;
	esac
done 3< <(rows)

if ((${#failures[@]} > 0)); then
	echo "FAIL: ${#failures[@]} of $steps exosuit test steps failed: ${failures[*]}"
	exit 1
fi
echo "PASS: exosuit headless test suite ($steps steps)"
