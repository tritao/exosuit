#!/bin/bash
# session.sh NAME [--drive SECONDS] [run.py args...]: launches the editor with NativeKit's latency trace and HashLink's
# GC timeline, records OS input with hook.py, optionally drives it with driver.py, then analyzes and writes a Perfetto
# trace. Output goes to runs/NAME/. Windows only. Hard limit 150 s.
set -u
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
name=$1; shift
drive=""
if [ "${1:-}" = "--drive" ]; then drive=$2; shift 2; fi
out="$here/runs/$name"
rm -rf "$out"; mkdir -p "$out"
win=$(cygpath -w "$out")
cd "$root"
export PATH="$root/haxeon/out:$root/haxeon/.tools/hashlink:$PATH"
export NK_LATENCY_TRACE="$win\app.txt" HL_GC_TIMELINE="$win\gc.txt"
python "$here/hook.py" "$out/hook.txt" 145 &
hookpid=$!
if [ -n "$drive" ]; then python "$here/driver.py" "$drive" --wait-window 90 > "$out/driver.log" 2>&1 & fi
timeout 150 python scripts/run.py "$@" > "$out/run.log" 2>&1
# The editor and LiveHost run as hl.exe children; stop the ones this session started, not compile servers.
powershell -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"Name='hl.exe'\" | Where-Object { \$_.CommandLine -notmatch 'haxeon[\\/]compiler' -and \$_.CreationDate -ge (Get-Date).AddSeconds(-160) } | ForEach-Object { Stop-Process -Id \$_.ProcessId -Force -ErrorAction SilentlyContinue }" 2>/dev/null
wait
python "$here/analyze.py" "$out/hook.txt" "$out/app.txt" "$out/gc.txt" | tee "$out/summary.txt"
python "$here/to_perfetto.py" "$out/hook.txt" "$out/app.txt" "$out/gc.txt" "$out/$name.pftrace"
