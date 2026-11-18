# Where the Android toolchain lives and what it must contain (dot-source it; env.ps1 and setup.ps1 do).
# The manifest is android/toolchain.json. The toolchain is per user and outside every checkout:
#   Windows %LOCALAPPDATA%\exosuit-android   macOS ~/Library/Application Support/exosuit-android   Linux ~/.local/share/exosuit-android
# EXOSUIT_ANDROID_HOME overrides the folder. Inside it: sdk, jdk, gradle-home, avd, user-home, downloads.
$script:AndroidRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$script:RepoRoot = (Resolve-Path (Join-Path $script:AndroidRoot '..')).Path
$script:Guard = Join-Path $script:RepoRoot 'docs/benchmarks/perf-harness/run-guarded.ps1'
$script:Manifest = Get-Content -Raw (Join-Path $script:AndroidRoot 'toolchain.json') | ConvertFrom-Json
$script:NdkVersion = $script:Manifest.ndk

function Get-HostPlatform {
    $arm = ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64')
    if ($arm) { throw 'Windows on ARM is not supported by the Android toolchain (the SDK tools are x64)' }
    return 'windows-x64'
}

function Get-ToolchainHome {
    if ($env:EXOSUIT_ANDROID_HOME) { return $env:EXOSUIT_ANDROID_HOME }
    return (Join-Path $env:LOCALAPPDATA 'exosuit-android')
}

# The JDK folder under <home>/jdk (the archive's own top folder, whatever the vendor named it), or $null.
function Find-ToolchainJdk([string]$toolchainHome) {
    $jdkRoot = Join-Path $toolchainHome 'jdk'
    if (-not (Test-Path $jdkRoot)) { return $null }
    foreach ($candidate in Get-ChildItem $jdkRoot -Directory | Where-Object { $_.Name -notlike '*.partial' }) {
        if (Test-Path (Join-Path $candidate.FullName 'bin/java.exe')) { return $candidate.FullName }
    }
    return $null
}

# Defaults the toolchain variables to the per-user folder when they are unset (or name a folder that is gone), and puts the
# SDK's cmake and ninja first on PATH. Variables the caller set to something that exists are left alone.
function Set-ToolchainEnvironment {
    $toolchainHome = Get-ToolchainHome
    $defaults = [ordered]@{
        ANDROID_HOME = Join-Path $toolchainHome 'sdk'
        GRADLE_USER_HOME = Join-Path $toolchainHome 'gradle-home'
        ANDROID_AVD_HOME = Join-Path $toolchainHome 'avd'
        ANDROID_USER_HOME = Join-Path $toolchainHome 'user-home'
    }
    foreach ($name in $defaults.Keys) {
        $current = [Environment]::GetEnvironmentVariable($name)
        if (-not $current -or -not (Test-Path $current)) {
            if ($current) { Write-Host "note: $name=$current does not exist; using $($defaults[$name])" }
            [Environment]::SetEnvironmentVariable($name, $defaults[$name])
        }
    }
    # ANDROID_SDK_ROOT is deprecated; a stale value would disagree with ANDROID_HOME.
    $env:ANDROID_SDK_ROOT = $env:ANDROID_HOME
    if (-not $env:JAVA_HOME -or -not (Test-Path (Join-Path $env:JAVA_HOME 'bin/java.exe'))) {
        $jdk = Find-ToolchainJdk $toolchainHome
        if ($jdk) { $env:JAVA_HOME = $jdk } elseif ($env:JAVA_HOME) { Write-Host "note: JAVA_HOME=$env:JAVA_HOME has no java.exe" }
    }
    $cmakeBin = Join-Path $env:ANDROID_HOME "cmake/$($script:Manifest.cmake)/bin"
    if ((Test-Path $cmakeBin) -and ($env:PATH -split ';' -notcontains $cmakeBin)) { $env:PATH = "$cmakeBin;$env:PATH" }
}

# Runs a program through the crash-dialog guard (CLAUDE.md); throws on a non-zero exit.
function Invoke-Guarded([string]$exe, [string]$arguments, [string]$log, [int]$timeout, [string]$workingDirectory = $script:RepoRoot) {
    New-Item -ItemType Directory -Force (Split-Path $log -Parent) | Out-Null
    & pwsh -NoProfile -File $script:Guard -TimeoutSeconds $timeout -Exe $exe "-ArgLine:$arguments" -Log $log -WorkingDirectory $workingDirectory
    if ($LASTEXITCODE -ne 0) { throw "$([IO.Path]::GetFileName($exe)) failed with exit code $LASTEXITCODE; see $log" }
}

# The items the toolchain must have: name, path that proves it, how setup.ps1 gets it. Used by -Check and by setup itself.
function Get-ToolchainItems {
    $toolchainHome = Get-ToolchainHome
    $sdk = Join-Path $toolchainHome 'sdk'
    $platform = Get-HostPlatform
    $abi = $script:Manifest.avd.systemImageByPlatform.$platform
    $image = $script:Manifest.avd.systemImage.$abi
    $items = [Collections.Generic.List[object]]::new()
    $items.Add([pscustomobject]@{ Name = 'cmdline-tools'; Path = Join-Path $sdk 'cmdline-tools/latest/bin/sdkmanager.bat'; Kind = 'cmdline' })
    $items.Add([pscustomobject]@{ Name = "jdk $($script:Manifest.jdk.version)"; Path = (Join-Path $toolchainHome 'jdk'); Kind = 'jdk' })
    foreach ($package in @($script:Manifest.sdkPackages) + @($image)) {
        $items.Add([pscustomobject]@{ Name = $package; Path = Join-Path $sdk (($package -replace ';', '/') + '/package.xml'); Kind = 'sdk' })
    }
    $items.Add([pscustomobject]@{ Name = "avd $($script:Manifest.avd.name)"; Path = Join-Path $toolchainHome "avd/$($script:Manifest.avd.name).ini"; Kind = 'avd' })
    return $items
}

function Test-ToolchainItem($item) {
    if ($item.Kind -eq 'jdk') { return [bool](Find-ToolchainJdk (Get-ToolchainHome)) }
    return (Test-Path $item.Path)
}
