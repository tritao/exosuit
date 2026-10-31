<#
.SYNOPSIS
Runs one instrumented build of an Exosuit checkout and collects everything the build report needs.

.DESCRIPTION
Starts the process and CPU sampler (optionally after waiting for a quiet machine), records a baseline, then runs
`scripts/build-windows.ps1 -SkipBootstrap --timings` in the checkout under the crash-dialog guard with every output
line timestamped. Afterwards it records ccache's counters, collects the static facts of every native build tree
(generator, flags, objects, compile times) and analyses the run.

Kinds:
  cold  the apps' build folders must not exist (a fresh checkout, or delete them and use a fresh -CcacheDir).
  noop  a build right after another one; the build folders must exist.
  warm  deletes agent/build, suit/build and graphical/build first, so CMake configures again and compiles go
        through the ccache that the previous build filled.

The checkout's haxeon must be bootstrapped (haxeon/out/haxeon-cli.hl present): the build is of the apps only.

Writes into -Out: <Name>.log (timestamped output), <Name>.jsonl (process samples), <Name>.cpu.csv (typeperf),
<Name>.guard.log, <Name>.ccache-before.txt / -after.txt, <Name>.meta.json, <Name>.static.json, <Name>.analysis.json.

.EXAMPLE
pwsh -NoProfile -File docs/benchmarks/build-report/measure.ps1 -Worktree C:\src\exosuit-fresh -Kind cold
pwsh -NoProfile -File docs/benchmarks/build-report/measure.ps1 -Worktree C:\src\exosuit-fresh -Kind noop
pwsh -NoProfile -File docs/benchmarks/build-report/measure.ps1 -Worktree C:\src\exosuit-fresh -Kind warm
#>
param(
	[Parameter(Mandatory)][string]$Worktree,
	[ValidateSet('cold', 'noop', 'warm')][string]$Kind = 'cold',
	[string]$Name = '',
	[string]$Out = '',
	# ccache's directory for this build. Empty uses the user's own (CCACHE_DIR or %LOCALAPPDATA%\ccache); a separate
	# one keeps other builds' compiles out of the counters, and an empty one makes a cold build truly cold.
	[string]$CcacheDir = '',
	[int]$TimeoutSeconds = 1500,
	[int]$BaselineSeconds = 30,
	# -WaitQuiet waits (up to -QuietMinutes) for -QuietChecks consecutive checks, 30 s apart, without another build.
	[switch]$WaitQuiet,
	[int]$QuietMinutes = 40,
	[int]$QuietChecks = 2
)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
. (Join-Path $here 'common.ps1')
$Worktree = (Resolve-Path $Worktree).Path
if (-not $Name) { $Name = $Kind }
$Out = Resolve-RunFolder $Worktree $Out
$python = (Get-Command python -ErrorAction Stop).Source

if (-not (Test-Path (Join-Path $Worktree 'scripts\build-windows.ps1'))) { throw "$Worktree is not an Exosuit checkout" }
$haxeon = Join-Path $Worktree 'haxeon'
if (-not (Test-Path (Join-Path $haxeon 'out\haxeon-cli.hl'))) { throw "$haxeon is not bootstrapped (no out\haxeon-cli.hl)" }
$appBuilds = 'agent', 'suit', 'graphical' | ForEach-Object { Join-Path $Worktree "$_\build" }
$present = @($appBuilds | Where-Object { Test-Path $_ })
switch ($Kind) {
	'cold' { if ($present) { throw "cold needs no app build folders, found: $($present -join ', ')" } }
	'noop' { if ($present.Count -ne $appBuilds.Count) { throw 'noop needs a built checkout: run a cold build first' } }
	'warm' { if ($present.Count -ne $appBuilds.Count) { throw 'warm needs a built checkout: run a cold build first' } }
}

if ($WaitQuiet) { Wait-QuietMachine $QuietMinutes $QuietChecks (Join-Path $Out "$Name.wait.log") }
if ($Kind -eq 'warm') {
	foreach ($dir in $appBuilds) { Write-Output "removing $dir"; Remove-Item -Recurse -Force $dir }
}

$ccache = Join-Path $haxeon '.tools\ccache\ccache.exe'
if ($CcacheDir) {
	New-Item -ItemType Directory -Force $CcacheDir | Out-Null
	$env:CCACHE_DIR = (Resolve-Path $CcacheDir).Path
}
function Invoke-Ccache([string]$Arguments) {
	Invoke-BuildReportGuarded -Exe $ccache -ArgLine $Arguments -TimeoutSeconds 60 -Capture
}
function Save-CcacheStats([string]$Path) {
	if (-not (Test-Path $ccache)) { "no pinned ccache at $ccache" | Set-Content $Path; return }
	$lines = @("# ccache --print-stats (CCACHE_DIR=$env:CCACHE_DIR)") + @(Invoke-Ccache '--print-stats') + @('# ccache --show-stats') + @(Invoke-Ccache '--show-stats')
	$lines | Set-Content -Encoding utf8 $Path
}
Save-CcacheStats (Join-Path $Out "$Name.ccache-before.txt")

$stop = Join-Path $Out "$Name.stop"
$samples = Join-Path $Out "$Name.jsonl"
if (Test-Path $stop) { Remove-Item $stop }
# The sampler also stops when this script's process ends (-WatchPid), so an interrupted run leaves no sampler behind.
$sampler = Start-Process -FilePath pwsh -WindowStyle Hidden -PassThru -ArgumentList @(
	'-NoProfile', '-File', (Join-Path $here 'sampler.ps1'), '-Out', $samples,
	'-MaxSeconds', ($TimeoutSeconds + $BaselineSeconds + 120), '-StopFile', $stop, '-WatchPid', $PID)
$code = $null
try {
	Start-Sleep -Seconds $BaselineSeconds
	$started = Get-Date
	Invoke-BuildReportGuarded -Exe pwsh -TimeoutSeconds $TimeoutSeconds -WorkingDirectory $Worktree -Log (Join-Path $Out "$Name.guard.log") `
		-ArgLine "-NoProfile -File `"$(Join-Path $here 'stamped-build.ps1')`" -Log `"$(Join-Path $Out "$Name.log")`""
	$code = $LASTEXITCODE
	$finished = Get-Date
	Start-Sleep -Seconds 5
} finally {
	New-Item -ItemType File -Force $stop | Out-Null
	if (-not $sampler.WaitForExit(30000)) {
		Stop-Process -Id $sampler.Id -Force -ErrorAction SilentlyContinue
		# The sampler stops its typeperf itself; when it had to be killed, stop typeperf too (its pid opens the samples).
		$first = Get-Content $samples -TotalCount 1 -ErrorAction SilentlyContinue
		if ($first) { try { Stop-Process -Id ([int]($first | ConvertFrom-Json).typeperfPid) -Force -ErrorAction SilentlyContinue } catch { } }
	}
	Remove-Item $stop -ErrorAction SilentlyContinue
}
Save-CcacheStats (Join-Path $Out "$Name.ccache-after.txt")

$git = $BuildReportGit
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
$meta = [ordered]@{
	name = $Name; kind = $Kind; exitCode = $code
	worktree = $Worktree
	exosuitCommit = (git @git -C $Worktree rev-parse HEAD); exosuitSubject = (git @git -C $Worktree log -1 --format=%s)
	haxeonCommit = (git @git -C $haxeon rev-parse HEAD); haxeonSubject = (git @git -C $haxeon log -1 --format=%s)
	started = $started.ToString('o'); finished = $finished.ToString('o')
	baselineSeconds = $BaselineSeconds; timeoutSeconds = $TimeoutSeconds
	waitedQuiet = $(if ($WaitQuiet) { "$QuietChecks checks, 30 s apart" } else { $null })
	ccacheDir = $(if ($env:CCACHE_DIR) { $env:CCACHE_DIR } else { Join-Path $env:LOCALAPPDATA 'ccache' })
	ccache = $(if (Test-Path $ccache) { (Invoke-Ccache '--version' | Select-Object -First 1) } else { $null })
	machine = [ordered]@{
		name = $env:COMPUTERNAME; cpu = $cpu.Name.Trim(); cores = $cpu.NumberOfCores; logical = [Environment]::ProcessorCount
		memoryGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
	}
}
$meta | ConvertTo-Json -Depth 4 | Set-Content -Encoding utf8 (Join-Path $Out "$Name.meta.json")

& $python -I (Join-Path $here 'collect_static.py') $Worktree (Join-Path $Out "$Name.static.json")
# analyze.py also adds what else ran during the build (other checkouts' build tools, the CPU baseline) to <Name>.meta.json.
& $python -I (Join-Path $here 'analyze.py') $Out $Name
Write-Output "build exit $code; run data in $Out"
exit $code
