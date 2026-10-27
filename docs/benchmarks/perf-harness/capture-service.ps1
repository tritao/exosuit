<#
.SYNOPSIS
Runs queued capture requests one at a time, so parallel work never launches two editors or moves the mouse at once.
The orchestrator starts it; workers submit with request-capture.ps1 and never launch the editor themselves.

Queue: <QueueDir>\pending\*.json (FIFO by name), then running\, then done\<id>.json with the result. Stops when
<QueueDir>\stop exists, or after IdleHours without a request.
#>
param(
	[string]$QueueDir = 'C:\Users\corbi\projects\exosuit\.claude\perf-captures',
	[double]$IdleHours = 8
)
$ErrorActionPreference = 'Stop'
foreach ($d in 'pending', 'running', 'done') { New-Item -ItemType Directory -Force (Join-Path $QueueDir $d) | Out-Null }
$log = Join-Path $QueueDir 'service.log'
function Note([string]$text) { $line = "[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $text; Add-Content $log $line; Write-Output $line }
# A request left in running\ by a service that died is retried once.
Get-ChildItem (Join-Path $QueueDir 'running') -Filter *.json | ForEach-Object { Move-Item $_.FullName (Join-Path $QueueDir "pending\$($_.Name)") -Force }
Note "capture service started (pid $PID)"
$lastWork = Get-Date
while ($true) {
	if (Test-Path (Join-Path $QueueDir 'stop')) { Note 'stop file found; exiting'; break }
	if (((Get-Date) - $lastWork).TotalHours -ge $IdleHours) { Note "idle for $IdleHours h; exiting"; break }
	$next = Get-ChildItem (Join-Path $QueueDir 'pending') -Filter *.json | Sort-Object Name | Select-Object -First 1
	if (-not $next) { Start-Sleep -Seconds 3; continue }
	$running = Join-Path $QueueDir "running\$($next.Name)"
	Move-Item $next.FullName $running -Force
	$request = Get-Content $running -Raw | ConvertFrom-Json
	$id = [IO.Path]::GetFileNameWithoutExtension($next.Name)
	$name = "$($request.stream)-$($request.name)"
	Note "start ${id}: $name root=$($request.root) profile=$($request.profile) file=$($request.file) live=$($request.live)"
	$measure = Join-Path $PSScriptRoot 'measure.ps1'
	$measureArgs = @('-NoProfile', '-File', $measure, '-Name', $name, '-Root', $request.root, '-Profile', $request.profile, '-File', $request.file)
	if ($request.live) { $measureArgs += '-Live' }
	$started = Get-Date
	$output = & pwsh @measureArgs 2>&1 | Out-String
	$code = $LASTEXITCODE
	$runDir = Join-Path $PSScriptRoot "runs\$name"
	$result = [ordered]@{
		id = $id; stream = $request.stream; name = $request.name; exitCode = $code
		seconds = [int]((Get-Date) - $started).TotalSeconds; runDir = $runDir
		metricsText = (Get-Content (Join-Path $runDir 'metrics.txt') -Raw -ErrorAction SilentlyContinue)
		metricsJson = (Join-Path $runDir 'metrics.json')
		trace = (Get-Content (Join-Path $runDir 'trace.txt') -Raw -ErrorAction SilentlyContinue)
		guard = (Get-Content (Join-Path $runDir 'guard.txt') -Raw -ErrorAction SilentlyContinue)
		output = $output
	}
	$result | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $QueueDir "done\$id.json")
	Remove-Item $running -Force
	Note "done  ${id}: exit $code in $($result.seconds) s"
	$lastWork = Get-Date
}
