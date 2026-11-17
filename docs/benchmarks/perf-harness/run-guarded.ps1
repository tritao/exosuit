<#
.SYNOPSIS
Runs one command under the crash-dialog guard with a hard timeout. Use it for every launch that can crash or show a
window: the app, hl.exe, test executables, ctest, build scripts.

.EXAMPLE
pwsh -NoProfile -File docs/benchmarks/perf-harness/run-guarded.ps1 -TimeoutSeconds 300 -Log build.log -Exe pwsh -ArgLine "-NoProfile -File scripts/build-windows.ps1 -SkipBootstrap"

`ArgLine` is passed to the program as one command line, exactly as written. Exit status: the command's own, 124 on
timeout, 125 when a crash or error dialog appeared (its text is printed and the process tree is stopped).
#>
param(
	[Parameter(Mandatory)][int]$TimeoutSeconds,
	[Parameter(Mandatory)][string]$Exe,
	[string]$ArgLine = '',
	[string]$Log = '',
	[string]$WorkingDirectory = (Get-Location).Path
)
$ErrorActionPreference = 'Stop'
# Guarded runs are unattended: what they start talks only to an exohost in a home of its own, and does not start it.
# A caller that sets EXOSUIT_EXOHOST_HOME (test-exohost.py, the GUI fixture, wt-run.ps1) keeps its own.
if (-not $env:EXOSUIT_EXOHOST_HOME) {
	$env:EXOSUIT_EXOHOST_HOME = Join-Path ([IO.Path]::GetTempPath()) ('exosuit-guard-exohost-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
	if (-not $env:EXOSUIT_EXOHOST_AUTOSTART) { $env:EXOSUIT_EXOHOST_AUTOSTART = '0' }
}
Import-Module (Join-Path $PSScriptRoot 'guard.psm1') -Force
$arguments = if ($ArgLine) { @($ArgLine) } else { @() }
$result = Invoke-Guarded -FilePath $Exe -ArgumentList $arguments -WorkingDirectory $WorkingDirectory -TimeoutSeconds $TimeoutSeconds -LogPath $Log
Write-Output (Format-GuardResult $result)
exit $result.ExitCode
