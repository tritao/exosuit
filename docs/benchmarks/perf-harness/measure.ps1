<#
.SYNOPSIS
Measures the editor in one checkout: launches it with the profiler, drives it through scenario.py with real OS input,
stops it, waits for the trace, and writes metrics. Only one measurement runs at a time on this machine (a named mutex),
because the scenario moves the real mouse.

.EXAMPLE
pwsh -NoProfile -File docs/benchmarks/perf-harness/measure.ps1 -Name baseline
pwsh -NoProfile -File docs/benchmarks/perf-harness/measure.ps1 -Name longline -File graphical/src/app/ApplicationIcons.hx -Profile instrument

Output: docs/benchmarks/perf-harness/runs/<Name>/ (run.log, guard.txt, scenario.json, metrics.txt, metrics.json, and
trace.txt naming the .pftrace). Build the checkout first (scripts/build-windows.ps1); this does not wait on a build.
Exit status 0 when metrics were written; 125 when a crash or error dialog appeared; 124 on the deadline.
#>
param(
	[Parameter(Mandatory)][string]$Name,
	[ValidateSet('sampling', 'instrument')][string]$Profile = 'sampling',
	[string]$File = 'src/editor/TextBuffer.hx',
	[switch]$Live,
	[int]$DeadlineSeconds = 0,
	[int]$LockWaitMinutes = 60,
	# The checkout to measure; this script's own by default. Output still goes under this script's runs folder.
	[string]$Root = ''
)
$ErrorActionPreference = 'Stop'
# Instrumented runs build and export more slowly; after a clean build their first launch also builds build-instrument.
if (-not $DeadlineSeconds) { $DeadlineSeconds = if ($Profile -eq 'instrument') { 900 } else { 300 } }
$editorLimit = if ($Profile -eq 'instrument') { 600 } else { 240 }
Import-Module (Join-Path $PSScriptRoot 'guard.psm1') -Force
$root = if ($Root) { (Resolve-Path $Root).Path } else { (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path }
$out = Join-Path $PSScriptRoot "runs\$Name"
if (Test-Path $out) { Remove-Item -Recurse -Force $out }
New-Item -ItemType Directory -Force (Join-Path $out 'state') | Out-Null
function Note([string]$text) { $line = "[{0:HH:mm:ss}] {1}" -f (Get-Date), $text; Add-Content (Join-Path $out 'measure.log') $line; Write-Host $line }

$lock = [System.Threading.Mutex]::new($false, 'Global\exosuit-perf-gui')
Note "waiting for the screen lock (one GUI measurement at a time)"
try { $acquired = $lock.WaitOne([TimeSpan]::FromMinutes($LockWaitMinutes)) } catch [System.Threading.AbandonedMutexException] { $acquired = $true }
if (-not $acquired) { Note "screen lock not free after $LockWaitMinutes min"; exit 124 }
$exit = 0
function Get-CpuLoad { [int]((Get-Counter '\Processor(_Total)\% Processor Time' -SampleInterval 1 -MaxSamples 3).CounterSamples | Measure-Object CookedValue -Average).Average }
try {
	# Parallel builds skew a capture; wait (bounded) for the machine to be quiet, and record the load either way.
	$quietDeadline = (Get-Date).AddMinutes(10)
	while (($load = Get-CpuLoad) -ge 30 -and (Get-Date) -lt $quietDeadline) { Note "CPU at $load%; waiting for a quiet machine"; Start-Sleep -Seconds 10 }
	Note "CPU at $load% before launch"
	"cpu_before_launch=$load" | Set-Content (Join-Path $out 'cpu.txt')
	Note "measuring $root ($Profile$(if ($Live) { ', live' }), file $File)"
	$env:PRAGTICAL_PORTABLE = Join-Path $out 'state'
	$runArgs = @('scripts/run.py')
	if ($Live) { $runArgs += '--live' }
	$runArgs += @("--profile=$Profile", $root, (Join-Path $root $File))
	$scenarioJson = Join-Path $out 'scenario.json'
	$log = Join-Path $out 'run.log'
	$state = @{ editor = $null; scenario = $null; stopped = $false; quietSince = 0; lastLength = -1 }
	# hl.exe gets paths with forward slashes; compare with both kinds of separator made alike.
	# Instrumented runs use graphical/build-instrument.
	$appPattern = [regex]::Escape(($root -replace '\\', '/')) + '/graphical/build[^/]*/host/'
	$tick = {
		param($process, $elapsed, $tree)
		if (-not $state.editor) {
			$state.editor = Get-CimInstance Win32_Process -Filter "Name='hl.exe'" |
				Where-Object { $tree.Contains([int]$_.ProcessId) -and ($_.CommandLine -replace '\\', '/') -match $appPattern -and $_.CommandLine -notmatch 'haxeon[\\/]compiler|--output' } |
				Select-Object -First 1
			if ($state.editor) {
				Note "editor started: pid $($state.editor.ProcessId) after $([int]$elapsed) s"
				$state.scenario = Start-Process python -ArgumentList @('-I', (Join-Path $PSScriptRoot 'scenario.py'), $scenarioJson, '--wait-window', '120') `
					-RedirectStandardOutput (Join-Path $out 'scenario.log') -RedirectStandardError (Join-Path $out 'scenario.err') -PassThru -WindowStyle Hidden
			}
		}
		if (-not $state.editor -and $elapsed -gt $editorLimit) { return "no editor process recognized after $editorLimit s (build failed, or the editor runs from an unexpected path)" }
		if ($state.scenario -and -not $state.stopped -and $state.scenario.HasExited) {
			Note "scenario finished (exit $($state.scenario.ExitCode)); stopping the editor so the profiler exports"
			Stop-Process -Id $state.editor.ProcessId -Force -ErrorAction SilentlyContinue
			$state.stopped = $true
		}
		$text = (Get-Content $log -Raw -ErrorAction SilentlyContinue) + (Get-Content "$log.err" -Raw -ErrorAction SilentlyContinue)
		if ($text -match 'profile written to|Perfetto trace:') {
			# Watch and live modes keep waiting for edits after the app exits.
			if ($text.Length -ne $state.lastLength) { $state.lastLength = $text.Length; $state.quietSince = $elapsed }
			elseif ($elapsed - $state.quietSince -ge 8) { return 'trace written' }
		}
		return $null
	}
	$result = Invoke-Guarded -FilePath python -ArgumentList $runArgs -WorkingDirectory $root -TimeoutSeconds $DeadlineSeconds -LogPath $log -OnTick $tick
	Format-GuardResult $result | Set-Content (Join-Path $out 'guard.txt')
	Note (Format-GuardResult $result)
	if ($state.scenario -and -not $state.scenario.HasExited) { Stop-Process -Id $state.scenario.Id -Force -ErrorAction SilentlyContinue }
	if ($result.ExitCode -in 124, 125) { $exit = $result.ExitCode }
} finally {
	# Compile servers and workspace agents of this checkout outlive the run; leave other checkouts' processes alone.
	Get-CimInstance Win32_Process -Filter "Name='hl.exe'" | Where-Object { $_.CommandLine -and ($_.CommandLine -replace '\\', '/').Contains(($root -replace '\\', '/')) } |
		ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
	$lock.ReleaseMutex()
	$lock.Dispose()
}
$text = (Get-Content (Join-Path $out 'run.log') -Raw -ErrorAction SilentlyContinue)
# Normal runs print "Perfetto trace: <path>", live runs "profile written to <path>".
$trace = if ($text -match '(?:profile written to|Perfetto trace:) (\S+\.pftrace)') { $Matches[1] } else { $null }
if (-not $trace) { Note 'no trace was written; see run.log and run.log.err'; exit $(if ($exit) { $exit } else { 1 }) }
$trace | Set-Content (Join-Path $out 'trace.txt')
$metricArgs = @('-I', (Join-Path $PSScriptRoot 'metrics.py'), $trace, '--json', (Join-Path $out 'metrics.json'))
if (Test-Path $scenarioJson) { $metricArgs += @('--scenario', $scenarioJson) }
$m = Invoke-Guarded -FilePath python -ArgumentList $metricArgs -WorkingDirectory $root -TimeoutSeconds 900 -LogPath (Join-Path $out 'metrics.txt')
Get-Content (Join-Path $out 'metrics.txt')
Note "metrics: $(Format-GuardResult $m)"
exit $(if ($exit) { $exit } elseif ($m.ExitCode -ne 0) { $m.ExitCode } else { 0 })
