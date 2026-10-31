<#
.SYNOPSIS
Times the Haxeon toolchain bootstrap of an Exosuit checkout (what -SkipBootstrap leaves out of measure.ps1).

.DESCRIPTION
Runs `cmake -P haxeon/cmake/Bootstrap.cmake` in the Visual Studio environment that scripts/build-windows.ps1 loads,
under the crash-dialog guard, with every output line timestamped. A fresh haxeon checkout downloads the pinned Haxe,
the formatter and ccache, and builds libffi, HashLink, the native runtime and the Haxeon CLI. Writes
<Name>.log, <Name>.guard.log and <Name>.meta.json into -Out.

.EXAMPLE
pwsh -NoProfile -File docs/benchmarks/build-report/bootstrap.ps1 -Worktree C:\src\exosuit-fresh
#>
param(
	[Parameter(Mandatory)][string]$Worktree,
	[string]$Name = 'bootstrap',
	[string]$Out = '',
	[int]$TimeoutSeconds = 1800,
	# -WaitQuiet waits (up to -QuietMinutes) for -QuietChecks consecutive checks, 30 s apart, without another build.
	[switch]$WaitQuiet,
	[int]$QuietMinutes = 40,
	[int]$QuietChecks = 2
)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
. (Join-Path $here 'common.ps1')
$Worktree = (Resolve-Path $Worktree).Path
$Out = Resolve-RunFolder $Worktree $Out
if ($WaitQuiet) { Wait-QuietMachine $QuietMinutes $QuietChecks (Join-Path $Out "$Name.wait.log") }
$started = Get-Date
Invoke-BuildReportGuarded -Exe pwsh -TimeoutSeconds $TimeoutSeconds -WorkingDirectory $Worktree -Log (Join-Path $Out "$Name.guard.log") `
	-ArgLine "-NoProfile -File `"$(Join-Path $here 'stamped-build.ps1')`" -Bootstrap -Log `"$(Join-Path $Out "$Name.log")`""
$code = $LASTEXITCODE
$git = $BuildReportGit
[ordered]@{
	name = $Name; kind = 'bootstrap'; exitCode = $code; worktree = $Worktree
	haxeonCommit = (git @git -C (Join-Path $Worktree 'haxeon') rev-parse HEAD)
	started = $started.ToString('o'); finished = (Get-Date).ToString('o')
	seconds = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)
} | ConvertTo-Json | Set-Content -Encoding utf8 (Join-Path $Out "$Name.meta.json")
Write-Output "bootstrap exit $code in $([math]::Round(((Get-Date) - $started).TotalSeconds)) s"
exit $code
