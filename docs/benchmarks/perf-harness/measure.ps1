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
	[int]$LockWaitMinutes = 7,
	# The checkout to measure; this script's own by default. Output still goes under this script's runs folder.
	[string]$Root = '',
	# Optional deterministic native fixture; capture its uniquely titled window without input.
	[string]$UiPreviewExecutable = '',
	[string[]]$UiPreviewArgs = @(),
	[string]$UiPreviewTitle = 'Exosuit UI exploration'
)
$ErrorActionPreference = 'Stop'
# A whole capture takes at most 7 minutes. Instrumented runs build and export more slowly; after a clean build, build
# build-instrument before measuring, because building it from scratch does not fit.
if (-not $DeadlineSeconds) { $DeadlineSeconds = if ($Profile -eq 'instrument') { 420 } else { 300 } }
$editorLimit = if ($Profile -eq 'instrument') { 240 } else { 150 }
# A capture records at most two minutes of the editor, from its launch to its exit; the build before it does not count.
$editorSeconds = 120
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
	if ($UiPreviewExecutable) {
		Add-Type -AssemblyName System.Drawing
		Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class PreviewWindowBounds {
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct Point { public int X, Y; }
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr window, out Rect rect);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr window, ref Point point);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr window, uint message, IntPtr w, IntPtr l);
}
'@
		$preview = @{ handle = [IntPtr]::Zero; foundAt = 0.0; captured = $false; error = $null }
		$tickPreview = {
			param($process, $elapsed, $tree)
			if ($preview.handle -eq [IntPtr]::Zero) {
				foreach ($id in $tree) {
					$p = Get-Process -Id $id -ErrorAction SilentlyContinue
					if ($p -and $p.MainWindowTitle -eq $UiPreviewTitle -and $p.MainWindowHandle -ne [IntPtr]::Zero) {
						$preview.handle = $p.MainWindowHandle; $preview.foundAt = $elapsed
						# Raise only this fixture, without focus or pointer movement, then let it repaint.
						if (-not [PreviewWindowBounds]::SetWindowPos($preview.handle, [IntPtr](-1), 0, 0, 0, 0, 0x53)) { $preview.error = 'Could not raise preview window' }
						break
					}
				}
			}
			if ($preview.handle -ne [IntPtr]::Zero -and -not $preview.captured -and $elapsed - $preview.foundAt -ge 3) {
				try {
				if ($preview.error) { throw $preview.error }
				$rect = [PreviewWindowBounds+Rect]::new()
				if (-not [PreviewWindowBounds]::GetClientRect($preview.handle, [ref]$rect)) { throw 'Could not get preview client bounds' }
				$origin = [PreviewWindowBounds+Point]::new()
				if (-not [PreviewWindowBounds]::ClientToScreen($preview.handle, [ref]$origin)) { throw 'Could not locate preview client' }
				$width = $rect.Right - $rect.Left; $height = $rect.Bottom - $rect.Top
				if ($width -le 0 -or $height -le 0) { throw 'Preview window has empty bounds' }
				$bitmap = [System.Drawing.Bitmap]::new($width, $height)
				$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
				try {
					$graphics.CopyFromScreen($origin.X, $origin.Y, 0, 0, $bitmap.Size)
					$bitmap.Save((Join-Path $out 'frame.png'), [System.Drawing.Imaging.ImageFormat]::Png)
				} finally { $graphics.Dispose(); $bitmap.Dispose() }
				$preview.captured = $true
				} catch { $preview.error = $_.Exception.Message }
				[void][PreviewWindowBounds]::PostMessage($preview.handle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
			}
			return $null
		}
		$result = Invoke-Guarded -FilePath $UiPreviewExecutable -ArgumentList $UiPreviewArgs -WorkingDirectory $root -TimeoutSeconds 60 -LogPath (Join-Path $out 'run.log') -OnTick $tickPreview
		Format-GuardResult $result | Set-Content (Join-Path $out 'guard.txt')
		Note (Format-GuardResult $result)
		if ($result.ExitCode -ne 0) { exit $result.ExitCode }
		if (-not $preview.captured) { Note "preview screenshot failed: $($preview.error)"; exit 1 }
		Note "captured $(Join-Path $out 'frame.png')"
		exit 0
	}
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
	$state = @{ editor = $null; editorAt = 0; scenario = $null; stopped = $false; quietSince = 0; lastLength = -1 }
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
				$state.editorAt = $elapsed
				Note "editor started: pid $($state.editor.ProcessId) after $([int]$elapsed) s"
				$state.scenario = Start-Process python -ArgumentList @('-I', (Join-Path $PSScriptRoot 'scenario.py'), $scenarioJson, '--wait-window', '120') `
					-RedirectStandardOutput (Join-Path $out 'scenario.log') -RedirectStandardError (Join-Path $out 'scenario.err') -PassThru -WindowStyle Hidden
			}
		}
		if (-not $state.editor -and $elapsed -gt $editorLimit) { return "no editor process recognized after $editorLimit s (build failed, or the editor runs from an unexpected path)" }
		if ($state.editor -and -not $state.stopped -and $elapsed - $state.editorAt -gt $editorSeconds) { return "the editor ran over $editorSeconds s" }
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
	if (-not $UiPreviewExecutable) {
		Get-CimInstance Win32_Process -Filter "Name='hl.exe'" | Where-Object { $_.CommandLine -and ($_.CommandLine -replace '\\', '/').Contains(($root -replace '\\', '/')) } |
			ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
	}
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
$m = Invoke-Guarded -FilePath python -ArgumentList $metricArgs -WorkingDirectory $root -TimeoutSeconds 300 -LogPath (Join-Path $out 'metrics.txt')
Get-Content (Join-Path $out 'metrics.txt')
Note "metrics: $(Format-GuardResult $m)"
exit $(if ($exit) { $exit } elseif ($m.ExitCode -ne 0) { $m.ExitCode } else { 0 })
