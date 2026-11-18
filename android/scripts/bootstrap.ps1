<#
Reports what is missing from the Android toolchain and from haxeon. It installs nothing: android/scripts/setup.ps1 installs the
toolchain (pinned by android/toolchain.json) and scripts/build-windows.ps1 builds haxeon.

  pwsh -NoProfile -File android/scripts/bootstrap.ps1
#>
. (Join-Path $PSScriptRoot 'env.ps1')
& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'setup.ps1') -Check
$problems = [Collections.Generic.List[string]]::new()
if ($LASTEXITCODE -ne 0) { $problems.Add('the Android toolchain is incomplete (android/scripts/setup.ps1)') }
foreach ($path in $Cli, $Hl) {
    if (-not (Test-Path $path)) { $problems.Add("$path is missing: build haxeon first (scripts/build-windows.ps1)") }
}
if ($problems.Count -gt 0) {
    $problems | ForEach-Object { Write-Host "missing: $_" }
    exit 1
}
Write-Host 'Android toolchain and haxeon are ready.'
