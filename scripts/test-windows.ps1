<#
.SYNOPSIS
Runs every headless test suite and driver that can run on Windows, and says PASS or FAIL for each.

.DESCRIPTION
The Windows entry point for what scripts/test.sh runs elsewhere. Build first (scripts/build-windows.ps1): the drivers
start the built agent.

Each suite runs
- through the dialog guard (docs/benchmarks/perf-harness/run-guarded.ps1) with a timeout of its own, so a crash dialog
  or a hang ends as a FAIL line (exit 125: a dialog appeared; 124: timeout; -1073741515: a DLL was not on PATH);
- with state of its own, made new for the run: PRAGTICAL_PORTABLE, EXOSUIT_AGENT_STATE_HOME and EXOSUIT_SUIT_HOME point
  into <run folder>\<suite>. A session another suite left behind makes tests fail (terminal-context-menu: "Tab keys
  must be unique"), and nothing reaches %LOCALAPPDATA%\Exosuit. TEMP stays where it is: the drivers make their fixtures
  there, and workspace-terminals reads a fixture's path off an 80-column terminal line, which a longer path wraps;
- with EXOSUIT_SUIT=off, so nothing registers with the user's suit or starts it.
Afterwards the processes the suite left running are stopped (a manager or a terminal host of a failed test): those
that descend from the suite's guard process (found by parent process id with start-time checks, polled while the suite
runs, so a child whose parent has exited is still known) and those started during the suite whose command line names the
suite's own folder. Nothing is stopped for merely naming this checkout or TEMP: another worker's build or a capture
may do that.
A suite that prints lines starting with SKIP skipped checks inside itself: it says "PASS (n skipped)" and the summary lists them.

No suite here opens a window or sends real input: the real-input GUI scenarios (docs/benchmarks/perf-harness) are not
run, and neither is tests/workspace-ui-smoke, which opens a window (see -List for what is left out and why).

.PARAMETER Only
Names of the suites to run (see -List). Default: all.

.PARAMETER List
Prints the suites, their timeouts and what is left out, and runs nothing.

.PARAMETER LogDir
Where each suite's output goes (<name>.log, <name>.log.err). Default: build\test-windows.

.PARAMETER KeepState
Keeps the run folder (state and fixtures) for looking at a failure.

.EXAMPLE
pwsh -NoProfile -File scripts/test-windows.ps1 -Only workspace-attachment,service-updates
#>
param(
    [string[]]$Only = @(),
    [switch]$List,
    [string]$LogDir = '',
    [switch]$KeepState
)
$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Guard = Join-Path $Root 'docs\benchmarks\perf-harness\run-guarded.ps1'
$Haxeon = if ($env:HAXEON_ROOT) { $env:HAXEON_ROOT } else { Join-Path $Root 'haxeon' }
if ($LogDir -eq '') { $LogDir = Join-Path $Root 'build\test-windows' }
$Only = @($Only | ForEach-Object { $_ -split ',' } | Where-Object { $_ })

$Suites = [System.Collections.Generic.List[object]]::new()
# A test project run with `haxeon run`. -Setup gets the suite's fixture folder and returns the program's arguments;
# it may set environment variables, which last for that suite only.
# -Python3: the test starts `python3`, which Windows has only as the Microsoft Store alias (see the python3 shim below).
function Add-Test([string]$Name, [int]$Timeout = 300, [scriptblock]$Setup = $null, [string]$Project = '', [switch]$Python3) {
    if ($Project -eq '') { $Project = "tests\$Name\haxeon.json" }
    $Suites.Add([pscustomobject]@{ Name = $Name; Kind = 'haxeon'; Target = $Project; Timeout = $Timeout; Setup = $Setup; Python3 = [bool]$Python3 })
}
# A Python driver under scripts\.
function Add-Driver([string]$Name, [string]$Script, [int]$Timeout = 600, [string]$Arguments = '') {
    $Suites.Add([pscustomobject]@{ Name = $Name; Kind = 'python'; Target = "scripts\$Script"; Timeout = $Timeout; Setup = $null; Arguments = $Arguments; Python3 = $false })
}

# The order of scripts/test.sh. The core entry checks shared document editing without a simulated native host.
Add-Test core -Project 'haxeon.json'
foreach ($name in 'plugin-host', 'command-clipboard', 'haxeon-rpc', 'workspace-catalog', 'workspace-migration', 'scm-git', 'scm-watch') { Add-Test $name }
Add-Driver workspace-scm test-workspace-scm.py
Add-Driver workspace-attachment test-workspace-attachment.py
Add-Driver workspace-manager-choice test-workspace-manager-choice.py
Add-Driver relay-setup test-relay-setup.py
Add-Test workspace-lifecycle
Add-Driver service-updates test-service-updates.py 900
Add-Driver agent-idle test-agent-idle.py 400
Add-Driver agent-manager test-agent-manager.py 400
Add-Driver agent-machine test-agent-machine.py
Add-Driver manager-owner-death test-manager-owner-death.py
Add-Driver workspace-identity test-workspace-identity.py
Add-Driver workspace-editor-identity test-workspace-editor-identity.py
Add-Driver workspace-terminals test-workspace-terminals.py
Add-Driver terminal-hosts test-terminal-hosts.py
Add-Driver workspace-agents test-workspace-agents.py 400
# Fake Claude, Codex and Pi peers only: never a real CLI, never a model.
Add-Driver claude-agents test-claude-agents.py
Add-Driver claude-session-names test-claude-session-names.py 120
Add-Driver native-session-names test-native-session-names.py
Add-Driver pi-agents test-pi-agents.py
Add-Driver pi-inputs test-pi-agents.py -Arguments '--inputs'
foreach ($name in 'application-test', 'problems', 'live-build-feed', 'host-capabilities-test', 'command-test', 'editor-view-test', 'tab-tooltip',
        'quick-picker', 'narrow-tabs', 'status-bar', 'terminal-context-menu', 'phone-last-view', 'sidebar-layout', 'terminal-keys',
        'workbench-drag', 'workbench-tree', 'context-snapshots', 'remote-access-panel', 'browser-pairing-url') { Add-Test $name }
Add-Test json-rpc-transport-test -Python3 -Setup { param($fixture) @((Join-Path $Root 'tests\fake_lsp.py')) }
foreach ($name in 'language-service-test', 'language-controller-test') {
    Add-Test $name -Python3 -Setup {
        param($fixture)
        @((Join-Path $Root 'tests\fake_lsp.py'), (New-Item -ItemType Directory -Force (Join-Path $fixture 'language-service-project')).FullName)
    }
}
Add-Test configuration-test -Setup {
    param($fixture)
    $project = New-Item -ItemType Directory -Force (Join-Path $fixture 'project')
    '{}' | Set-Content -NoNewline (Join-Path $fixture 'user.json')
    '{}' | Set-Content -NoNewline (Join-Path $fixture 'project.json')
    @((Join-Path $fixture 'user.json'), (Join-Path $fixture 'project.json'), $project.FullName, (Join-Path $fixture 'user.json'))
}
Add-Test document-test -Setup {
    param($fixture)
    $file = Join-Path $fixture 'document-save-smoke.txt'
    [IO.File]::WriteAllText($file, "saved by Haxeon`n")
    @($file)
}
Add-Test file-deletion -Setup { param($fixture) @((Join-Path $fixture 'file-deletion-test')) }
Add-Test saved-workspace -Setup { param($fixture) $env:PRAGTICAL_PORTABLE = Join-Path $fixture 'state'; @((Join-Path $fixture 'roots')) }
Add-Test active-context -Setup { param($fixture) $env:PRAGTICAL_PORTABLE = Join-Path $fixture 'state'; @((Join-Path $fixture 'roots')) }
foreach ($name in 'layout-controls', 'layout-modes', 'agent-scope', 'session-links', 'session-chat-ui', 'session-diff-regression', 'agent-snapshot-client') { Add-Test $name }
Add-Test agent-content-store -Setup { param($fixture) @((New-Item -ItemType Directory -Force (Join-Path $fixture 'content-store')).FullName) }
# The native Codex adapter and proxy bridge against the deterministic fake peer; never a real inference turn.
Add-Test codex-history -Setup {
    param($fixture)
    @((New-Item -ItemType Directory -Force (Join-Path $fixture 'codex-history')).FullName, (Get-Command python).Source,
        (Join-Path $Root 'scripts\run-codex-proxy.py'), (Join-Path $Root 'tests\workspace-agents\fake-codex.py'))
}
foreach ($name in 'path-key', 'workspace-target', 'workspace-catalog-pool', 'project-scan-yield') { Add-Test $name }
# Source compilation, compatible patches, structural reloads and failure rollback.
Add-Test dynamic-plugin-test -Setup {
    param($fixture)
    Copy-Item (Join-Path $Root 'plugins\example\plugin.conf'), (Join-Path $Root 'plugins\example\Main.hx') $fixture
    @((Join-Path $fixture 'plugin.conf'), (Join-Path $fixture 'Main.hx'))
}
# suit itself, with its own isolated home and a real workspace manager; not the editor window (--editor).
Add-Driver suit test-suit.py 600 '--real-manager'

$LeftOut = @(
    'plugin-host-bindings, sqlite-native, terminal-native, terminal-session-native, noise-native, processes-native, workspace-transport, relay, workspace-persistence, workspace-rpc-wasm: Bash scripts that build with cc',
    'process-test, plugin-test, workspace-test: need build/process-fixture (tests/process_fixture.c built with cc); workspace-test also needs an unreadable file (chmod 000)',
    'directory-scan: needs a folder made unreadable with chmod 000',
    'hosted-relay (scripts/test-hosted-relay.py): needs the origin of a hosted relay to connect to',
    'workspace-ui-smoke (scripts/test-workspace-ui.sh): opens a window for every phase (xvfb-run elsewhere); there is no hidden display on Windows',
    'scripts/test-*-ui.py, test-*-ui.sh: Xvfb and xdotool',
    'docs/benchmarks/perf-harness/gui_scenarios: real input; run them through measure.ps1 or the capture queue, one at a time'
)

if ($List) {
    $Suites | ForEach-Object { '{0,-28} {1,-7} {2,4} s  {3}' -f $_.Name, $_.Kind, $_.Timeout, $_.Target }
    ''; 'Left out:'; $LeftOut | ForEach-Object { "  $_" }
    exit 0
}
$unknown = @($Only | Where-Object { $_ -notin $Suites.Name })
if ($unknown) { Write-Host "Unknown suite(s): $($unknown -join ', '). See -List."; exit 2 }
$chosen = @($Suites | Where-Object { $Only.Count -eq 0 -or $_.Name -in $Only })
if (-not (Test-Path (Join-Path $Root 'agent\build\host\main.hl'))) { Write-Host 'The agent is not built: run scripts\build-windows.ps1 first.'; exit 2 }
if (-not (Test-Path (Join-Path $Haxeon '.tools\hashlink\hl.exe'))) { Write-Host "No HashLink under $Haxeon\.tools: run scripts\build-windows.ps1 first."; exit 2 }

New-Item -ItemType Directory -Force $LogDir | Out-Null
# Short: a fixture's path ends up in command lines and, for some tests, in file names.
$Run = Join-Path ([IO.Path]::GetTempPath()) ('exwt-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $Run | Out-Null

# What every suite sees. Every hl.exe needs Haxeon's runtime and HashLink on PATH.
$env:HAXEON_ROOT = $Haxeon
$env:HAXEON_HOME = $Haxeon
$env:PATH = "$Haxeon\out;$Haxeon\.tools\hashlink;$env:PATH"
$env:EXOSUIT_SUIT = 'off'
if (-not $env:HAXEON_UI_VERIFY_RETENTION) { $env:HAXEON_UI_VERIFY_RETENTION = '1' }
foreach ($name in 'EXOSUIT_PROJECT_ROOT', 'EXOSUIT_AGENT_LAUNCHER', 'EXOSUIT_AGENT_ALWAYS_AVAILABLE', 'XDG_STATE_HOME') { Remove-Item "env:$name" -ErrorAction SilentlyContinue }
$Isolated = 'PRAGTICAL_PORTABLE', 'EXOSUIT_AGENT_STATE_HOME', 'EXOSUIT_SUIT_HOME'
# The python3 shim: some tests start their fake language server by the name `python3`, which Windows has only as the Microsoft
# Store alias (it offers the Store when Python came from elsewhere). A virtual environment's launcher, renamed python3.exe
# in a folder of its own that comes first on PATH, runs this Python under that name; nothing else changes on PATH.
if (@($chosen | Where-Object { $_.Python3 }).Count) {
    $venv = Join-Path $Run 'python3'
    & python -m venv --without-pip --system-site-packages $venv
    $shim = New-Item -ItemType Directory -Force (Join-Path $venv 'shim')
    Copy-Item (Join-Path $venv 'Scripts\python.exe') (Join-Path $shim 'python3.exe')
    $env:PATH = "$($shim.FullName);$env:PATH"
}
$Temp = [IO.Path]::GetTempPath().TrimEnd('\')

function Quote([string]$value) { if ($value -match '[\s"]') { '"' + ($value -replace '"', '\"') + '"' } else { $value } }

# Descendants of `$rootPid` among `$all` (Win32_Process rows): a process counts when its parent is the root or a known
# descendant and the parent started no later than the child (a reused parent id belongs to an unrelated, later process).
function Get-Descendants([int]$rootPid, $all) {
    $known = @{}
    $byId = @{}
    foreach ($p in $all) { $byId[[int]$p.ProcessId] = $p }
    $changed = $true
    while ($changed) {
        $changed = $false
        foreach ($p in $all) {
            if ($known.ContainsKey([int]$p.ProcessId) -or [int]$p.ProcessId -eq $rootPid) { continue }
            $parentId = [int]$p.ParentProcessId
            if ($parentId -ne $rootPid -and -not $known.ContainsKey($parentId)) { continue }
            $parent = $byId[$parentId]
            if ($parent -and $parent.CreationDate -gt $p.CreationDate) { continue }
            $known[[int]$p.ProcessId] = $p.CreationDate
            $changed = $true
        }
    }
    $known
}

function Stop-Leftovers([string]$folder, [datetime]$since, $descendants) {
    $all = @(Get-CimInstance Win32_Process)
    $victims = @{}
    foreach ($p in $all) {
        if ($p.ProcessId -eq $PID) { continue }
        # A recorded descendant still alive with the start time it had (a reused id is another process).
        $recorded = $descendants.ContainsKey([int]$p.ProcessId) -and $descendants[[int]$p.ProcessId] -eq $p.CreationDate
        $named = $p.CommandLine -and $p.CreationDate -ge $since -and $p.CommandLine.Contains($folder)
        if ($recorded -or $named) { $victims[[int]$p.ProcessId] = $true }
    }
    foreach ($id in $victims.Keys) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
    $victims.Count
}

function Meaning([int]$code) {
    switch ($code) {
        124 { 'timeout' }
        125 { 'an error dialog appeared' }
        -1073741515 { 'a DLL was not found (PATH)' }
        default { "exit $code" }
    }
}

$results = @()
foreach ($suite in $chosen) {
    $home_ = Join-Path $Run $suite.Name
    $fixture = Join-Path $home_ 'fixture'
    foreach ($folder in 'portable', 'agent-state', 'suit', 'fixture') { New-Item -ItemType Directory -Force (Join-Path $home_ $folder) | Out-Null }
    $saved = @{}
    foreach ($name in $Isolated) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
    $env:PRAGTICAL_PORTABLE = Join-Path $home_ 'portable'
    $env:EXOSUIT_AGENT_STATE_HOME = Join-Path $home_ 'agent-state'
    $env:EXOSUIT_SUIT_HOME = Join-Path $home_ 'suit'
    $log = Join-Path $LogDir ($suite.Name + '.log')
    Remove-Item $log, "$log.err" -ErrorAction SilentlyContinue
    $started = Get-Date
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $code = 1
    $descendants = @{}
    try {
        if ($suite.Kind -eq 'haxeon') {
            $arguments = @('scripts\haxeon_cli.py', 'run', '--project', $suite.Target)
            if ($env:HAXEON_SELF_HOSTED -eq '1') { $arguments += '--self-hosted' }
            # Forward slashes, as test.sh passes: the tests join and split these paths with "/".
            $passed = if ($suite.Setup) { @(& $suite.Setup $fixture | ForEach-Object { ([string]$_) -replace '\\', '/' }) } else { @() }
            if ($passed.Count) { $arguments += @('--') + $passed }
        } else {
            $arguments = @($suite.Target)
            if ($suite.Arguments) { $arguments += $suite.Arguments }
        }
        $line = ($arguments | ForEach-Object { Quote ([string]$_) }) -join ' '
        $start = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
        $start.UseShellExecute = $false
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        foreach ($a in '-NoProfile', '-File', $Guard, '-TimeoutSeconds', [string]$suite.Timeout, '-Exe', 'python', "-ArgLine:$line", '-Log', $log, '-WorkingDirectory', $Root) { $start.ArgumentList.Add($a) }
        $proc = [Diagnostics.Process]::Start($start)
        $out = $proc.StandardOutput.ReadToEndAsync()
        $err = $proc.StandardError.ReadToEndAsync()
        # Poll the guard's process tree while the suite runs: once a parent exits, its children can no longer be traced to the guard.
        while (-not $proc.WaitForExit(1500)) {
            $tree = Get-Descendants $proc.Id @(Get-CimInstance Win32_Process)
            foreach ($k in $tree.Keys) { $descendants[$k] = $tree[$k] }
        }
        $proc.WaitForExit()
        $code = $proc.ExitCode
        (@($out.Result) + @($err.Result)) -join "`n" | Set-Content (Join-Path $LogDir ($suite.Name + '.guard'))
    } catch {
        "test-windows.ps1: $_" | Add-Content "$log.err"
    } finally {
        foreach ($name in $Isolated) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
    }
    $left = Stop-Leftovers $home_ $started $descendants
    $skips = @(if (Test-Path $log) { Get-Content $log | Where-Object { $_ -match '^SKIP' } })
    $seconds = [int]$timer.Elapsed.TotalSeconds
    $note = if ($left) { " (stopped $left process(es) it left running)" } else { '' }
    if ($code -eq 0) {
        $skipNote = if ($skips.Count) { " ($($skips.Count) skipped)" } else { '' }
        Write-Host ('PASS{3} {0,-28} {1,4} s{2}' -f $suite.Name, $seconds, $note, $skipNote)
    } else {
        Write-Host ('FAIL {0,-28} {1,4} s  {2}{3}  -> {4}' -f $suite.Name, $seconds, (Meaning $code), $note, $log)
    }
    $results += [pscustomobject]@{ Name = $suite.Name; Passed = ($code -eq 0); Code = $code; Seconds = $seconds; Skips = $skips }
}

if (-not $KeepState) { Remove-Item -Recurse -Force $Run -ErrorAction SilentlyContinue } else { Write-Host "State kept in $Run" }
$failed = @($results | Where-Object { -not $_.Passed })
Write-Host ''
if ($failed) {
    Write-Host ("FAIL: {0} of {1} suites failed: {2}" -f $failed.Count, $results.Count, ($failed.Name -join ', '))
    Write-Host "Output of each suite: $LogDir\<name>.log and .log.err"
    foreach ($r in @($results | Where-Object { $_.Skips.Count })) { foreach ($s in $r.Skips) { Write-Host "  skipped in $($r.Name): $s" } }
    exit 1
}
$skipped = @($results | Where-Object { $_.Skips.Count })
Write-Host ("PASS: {0} suites" -f $results.Count)
if ($skipped) {
    Write-Host ("{0} suite(s) skipped checks inside themselves:" -f $skipped.Count)
    foreach ($r in $skipped) { foreach ($s in $r.Skips) { Write-Host "  $($r.Name): $s" } }
}
exit 0
