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
# Guarded runs are unattended: what they start neither registers with the user's suit nor starts it.
# test-suit.py sets EXOSUIT_SUIT=isolated with its own EXOSUIT_SUIT_HOME to exercise suit itself.
if (-not $env:EXOSUIT_SUIT) { $env:EXOSUIT_SUIT = 'off' }
Import-Module (Join-Path $PSScriptRoot 'guard.psm1') -Force
$arguments = if ($ArgLine) { @($ArgLine) } else { @() }
$result = Invoke-Guarded -FilePath $Exe -ArgumentList $arguments -WorkingDirectory $WorkingDirectory -TimeoutSeconds $TimeoutSeconds -LogPath $Log
Write-Output (Format-GuardResult $result)
exit $result.ExitCode
