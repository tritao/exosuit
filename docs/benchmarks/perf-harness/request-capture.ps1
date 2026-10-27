<#
.SYNOPSIS
Asks the capture service to measure a checkout, waits for the result and prints its metrics. Workers use this instead
of launching the editor: only the service drives the GUI, one capture at a time.

.EXAMPLE
pwsh -NoProfile -File docs/benchmarks/perf-harness/request-capture.ps1 -Stream A -Name after-input-first
pwsh -NoProfile -File docs/benchmarks/perf-harness/request-capture.ps1 -Stream C -Name longline -File graphical/src/app/ApplicationIcons.hx -Profile instrument

Build the checkout first. `Root` defaults to the checkout this script is in. Exit status: the capture's (0 ok,
125 a crash or error dialog appeared, 124 deadline), or 3 when no result arrived in time.
#>
param(
	[Parameter(Mandatory)][string]$Stream,
	[Parameter(Mandatory)][string]$Name,
	[ValidateSet('sampling', 'instrument')][string]$Profile = 'sampling',
	[string]$File = 'src/editor/TextBuffer.hx',
	[switch]$Live,
	[string]$Root = '',
	# One capture takes at most 7 minutes (measure.ps1); a request waits for one, plus the queue picking it up.
	[int]$WaitMinutes = 10,
	[string]$QueueDir = 'C:\Users\corbi\projects\exosuit\.claude\perf-captures'
)
$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path }
if (-not (Test-Path (Join-Path $QueueDir 'pending'))) { Write-Output "capture service queue $QueueDir does not exist; ask the orchestrator"; exit 3 }
$id = '{0:yyyyMMdd-HHmmss-fff}-{1}-{2}' -f (Get-Date), $Stream, ($Name -replace '[^A-Za-z0-9_-]', '_')
$request = [ordered]@{ stream = $Stream; name = $Name; root = $Root; profile = $Profile; file = $File; live = [bool]$Live }
$tmp = Join-Path $QueueDir "pending\$id.tmp"
$request | ConvertTo-Json | Set-Content $tmp
Move-Item $tmp (Join-Path $QueueDir "pending\$id.json")
Write-Output "queued capture $id; waiting (captures run one at a time)"
$done = Join-Path $QueueDir "done\$id.json"
$deadline = (Get-Date).AddMinutes($WaitMinutes)
while (-not (Test-Path $done)) {
	if ((Get-Date) -gt $deadline) { Write-Output "no result after $WaitMinutes min"; exit 3 }
	Start-Sleep -Seconds 5
}
Start-Sleep -Milliseconds 500
$result = Get-Content $done -Raw | ConvertFrom-Json
Write-Output "capture $id exit $($result.exitCode) in $($result.seconds) s; run dir $($result.runDir)"
if ($result.guard) { Write-Output $result.guard.Trim() }
if ($result.metricsText) { Write-Output $result.metricsText } else { Write-Output $result.output }
exit $result.exitCode
