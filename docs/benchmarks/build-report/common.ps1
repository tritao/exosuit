# Shared by measure.ps1 and bootstrap.ps1: dot-source it.

# Git options for Exosuit checkouts: submodules are not compared or recursed into.
$BuildReportGit = @('-c', 'diff.ignoreSubmodules=all', '-c', 'submodule.recurse=false')
$BuildReportGuard = Join-Path $PSScriptRoot '..\perf-harness\run-guarded.ps1'

# The run folder: -Out when given, else %LOCALAPPDATA%\Exosuit\build-reports\<checkout folder name>. Created; returned
# as a full path.
function Resolve-RunFolder([string]$Worktree, [string]$Out) {
	if (-not $Out) { $Out = Join-Path $env:LOCALAPPDATA ('Exosuit\build-reports\' + (Split-Path $Worktree -Leaf)) }
	New-Item -ItemType Directory -Force $Out | Out-Null
	(Resolve-Path $Out).Path
}

# Waits for -Checks consecutive checks, 30 s apart, without another build (wait-quiet.ps1), logging to $Log.
function Wait-QuietMachine([int]$Minutes, [int]$Checks, [string]$Log) {
	pwsh -NoProfile -File (Join-Path $PSScriptRoot 'wait-quiet.ps1') -MaxMinutes $Minutes -QuietChecks $Checks | Tee-Object -FilePath $Log
	if ($LASTEXITCODE -ne 0) { throw "the machine did not become quiet within $Minutes minutes" }
}

# Runs a program under the crash-dialog guard. With -Capture, returns the program's standard output lines instead of
# writing a log of them. Sets $LASTEXITCODE to the program's exit code (124 timeout, 125 dialog).
function Invoke-BuildReportGuarded {
	param([string]$Exe, [string]$ArgLine, [int]$TimeoutSeconds, [string]$WorkingDirectory = (Get-Location).Path,
		[string]$Log = '', [switch]$Capture)
	$temporary = $null
	if ($Capture) {
		$temporary = Join-Path ([IO.Path]::GetTempPath()) ('build-report-' + [guid]::NewGuid().ToString('n') + '.log')
		$Log = $temporary
	}
	$arguments = @('-NoProfile', '-File', $BuildReportGuard, '-TimeoutSeconds', $TimeoutSeconds, '-Exe', $Exe,
		"-ArgLine:$ArgLine", '-WorkingDirectory', $WorkingDirectory)
	if ($Log) { $arguments += @('-Log', $Log) }
	if ($Capture) {
		pwsh @arguments | Out-Null
		$code = $LASTEXITCODE
		$lines = @(Get-Content $temporary -ErrorAction SilentlyContinue)
		Remove-Item $temporary, "$temporary.err" -ErrorAction SilentlyContinue
		$global:LASTEXITCODE = $code
		return $lines
	}
	pwsh @arguments
}
