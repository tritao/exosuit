<#
Installs the whole Android toolchain, pinned by android/toolchain.json, into the per-user folder
%LOCALAPPDATA%\exosuit-android (sdk, jdk, gradle-home, avd, user-home, downloads), outside every checkout:

  pwsh -NoProfile -File android/scripts/setup.ps1 [-Check] [-Force] [-SkipAvd]

  (no switch)  installs what is missing, in order: cmdline-tools, JDK 21, the SDK packages (platform-tools, emulator,
               platform, build-tools, NDK, cmake with ninja, the system image), then the AVD exosuit-s8. Idempotent and
               resumable: a finished item is skipped, an interrupted download continues, a half-extracted folder is redone.
               Running it again after the folder was deleted repairs it. It accepts the Android SDK licenses
               (https://developer.android.com/studio/terms) as sdkmanager's --licenses would.
  -Check       installs nothing; prints each item as ok or MISSING and exits 1 when anything is missing.
  -Force       installs the SDK packages again even when present.
  -SkipAvd     leaves the emulator image and the AVD out (build only).

Downloads are checked against the SHA-1/SHA-256 in the manifest. The Gradle distribution is fetched by the wrapper into
gradle-home on the first build. Needs: pwsh 7, curl.exe and tar.exe (both ship with Windows 10/11).
#>
param([switch]$Check, [switch]$Force, [switch]$SkipAvd)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'toolchain-lib.ps1')
$toolchainHome = Get-ToolchainHome
$platform = Get-HostPlatform
$sdk = Join-Path $toolchainHome 'sdk'
$downloads = Join-Path $toolchainHome 'downloads'
$logs = Join-Path $toolchainHome 'logs'

$items = @(Get-ToolchainItems)
if ($SkipAvd) { $items = @($items | Where-Object { $_.Kind -ne 'avd' -and $_.Name -notlike 'system-images;*' }) }

if ($Check) {
    Write-Host "Android toolchain folder: $toolchainHome"
    $missing = 0
    foreach ($item in $items) {
        if (Test-ToolchainItem $item) { Write-Host ("  ok       {0}" -f $item.Name) } else { Write-Host ("  MISSING  {0}" -f $item.Name); $missing++ }
    }
    foreach ($tool in 'cmake', 'ninja') {
        $toolPath = Join-Path $sdk "cmake/$($Manifest.cmake)/bin/$tool.exe"
        if (Test-Path $toolPath) { Write-Host "  ok       $tool ($toolPath)" } else { Write-Host "  MISSING  $tool (in package cmake;$($Manifest.cmake))"; $missing++ }
    }
    if ($missing) { Write-Host "$missing item(s) missing: run android/scripts/setup.ps1"; exit 1 }
    Write-Host 'Android toolchain is complete.'
    exit 0
}

New-Item -ItemType Directory -Force $toolchainHome, $downloads, $logs, (Join-Path $toolchainHome 'gradle-home'), (Join-Path $toolchainHome 'avd'), (Join-Path $toolchainHome 'user-home') | Out-Null

# Downloads $url to downloads\<name> (resuming a partial file), checks the hash, returns the path.
function Get-Download([string]$url, [string]$algorithm, [string]$expected) {
    $name = [IO.Path]::GetFileName(([Uri]$url).AbsolutePath)
    $path = Join-Path $downloads $name
    $verified = "$path.verified"
    if ((Test-Path $path) -and (Test-Path $verified) -and ([IO.File]::ReadAllText($verified).Trim() -eq $expected)) { return $path }
    Write-Host "  downloading $name"
    for ($attempt = 1; $attempt -le 4; $attempt++) {
        & curl.exe -L --fail -sS -C - --retry 3 --retry-delay 5 --max-time 3600 -o $path $url
        if ($LASTEXITCODE -eq 0) { break }
        if ($LASTEXITCODE -eq 33 -or $LASTEXITCODE -eq 416) { Remove-Item $path -Force -ErrorAction SilentlyContinue }  # server refused the range: start over
        if ($attempt -eq 4) { throw "download of $url failed (curl exit $LASTEXITCODE)" }
    }
    $actual = (Get-FileHash $path -Algorithm $algorithm).Hash.ToLowerInvariant()
    if ($actual -ne $expected.ToLowerInvariant()) {
        Remove-Item $path -Force
        throw "$name has $algorithm $actual, the manifest pins $expected (the file was deleted; run setup again)"
    }
    [IO.File]::WriteAllText($verified, $expected)
    return $path
}

# Extracts into a fresh <target>.partial and renames it with the archive's single top folder: the target exists only when complete.
function Expand-TopFolder([string]$archive, [string]$target, [string]$expectedTop = '') {
    $partial = "$target.partial"
    Remove-Item -Recurse -Force $partial -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $partial | Out-Null
    & tar.exe -xf $archive -C $partial
    if ($LASTEXITCODE -ne 0) { throw "tar failed to extract $archive" }
    $top = @(Get-ChildItem $partial)
    if ($top.Count -ne 1) { throw "$archive does not hold exactly one top folder" }
    Remove-Item -Recurse -Force $target -ErrorAction SilentlyContinue
    Move-Item $top[0].FullName $target
    Remove-Item -Recurse -Force $partial
}

foreach ($item in $items) {
    if (Test-ToolchainItem $item) { continue }
    if ($item.Kind -eq 'cmdline') {
        Write-Host "== cmdline-tools"
        $entry = $Manifest.cmdlineTools.$platform
        $zip = Get-Download $entry.url 'SHA1' $entry.sha1
        New-Item -ItemType Directory -Force (Join-Path $sdk 'cmdline-tools') | Out-Null
        Expand-TopFolder $zip (Join-Path $sdk 'cmdline-tools/latest')
    } elseif ($item.Kind -eq 'jdk') {
        Write-Host "== jdk $($Manifest.jdk.version)"
        $entry = $Manifest.jdk.$platform
        $zip = Get-Download $entry.url 'SHA256' $entry.sha256
        New-Item -ItemType Directory -Force (Join-Path $toolchainHome 'jdk') | Out-Null
        Expand-TopFolder $zip (Join-Path $toolchainHome "jdk/temurin-$($Manifest.jdk.version -replace '\+', '_')")
    }
}

# From here the tools run with the toolchain's own environment.
Set-ToolchainEnvironment
if (-not $env:JAVA_HOME) { throw 'The JDK is missing after its install step' }
$sdkmanager = Join-Path $sdk 'cmdline-tools/latest/bin/sdkmanager.bat'
$avdmanager = Join-Path $sdk 'cmdline-tools/latest/bin/avdmanager.bat'

# One sdkmanager call per missing package keeps a failed download from hiding which one broke; a finished package is skipped.
$pending = @($items | Where-Object { $_.Kind -eq 'sdk' -and ($Force -or -not (Test-ToolchainItem $_)) })
if ($pending.Count -gt 0) {
    Write-Host "== accepting SDK licenses"
    $answers = Join-Path $toolchainHome 'yes.txt'
    [IO.File]::WriteAllText($answers, ((1..40 | ForEach-Object { 'y' }) -join "`r`n") + "`r`n")
    Invoke-Guarded $env:ComSpec ('/d /s /c ""' + $sdkmanager + '" --sdk_root="' + $sdk + '" --licenses < "' + $answers + '""') (Join-Path $logs 'licenses.log') 300
    foreach ($item in $pending) {
        Write-Host "== $($item.Name)"
        Invoke-Guarded $env:ComSpec ('/d /s /c ""' + $sdkmanager + '" --sdk_root="' + $sdk + '" "' + $item.Name + '""') `
            (Join-Path $logs (($item.Name -replace '[^A-Za-z0-9.-]', '_') + '.log')) 3600
        if (-not (Test-ToolchainItem $item)) { throw "sdkmanager finished but $($item.Name) is not at $($item.Path); see $logs" }
    }
}

if (-not $SkipAvd) {
    $avd = $Manifest.avd
    $abi = $avd.systemImageByPlatform.$platform
    $ini = Join-Path $env:ANDROID_AVD_HOME "$($avd.name).ini"
    if (-not (Test-Path $ini)) {
        Write-Host "== avd $($avd.name)"
        Invoke-Guarded $env:ComSpec ('/d /s /c "echo no | "' + $avdmanager + '" create avd -n ' + $avd.name + ' -k "' + $avd.systemImage.$abi + '" -d ' + $avd.device + ' --force"') `
            (Join-Path $logs 'avd.log') 300
    }
}

if ($SkipAvd) { & $PSCommandPath -Check -SkipAvd } else { & $PSCommandPath -Check }
exit $LASTEXITCODE
