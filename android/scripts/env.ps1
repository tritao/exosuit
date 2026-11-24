# Shared by the Android scripts (dot-source it). The toolchain comes from the per-user folder that setup.ps1 fills
# (toolchain-lib.ps1: %LOCALAPPDATA%\exosuit-android). ANDROID_HOME, JAVA_HOME, GRADLE_USER_HOME, ANDROID_AVD_HOME and
# ANDROID_USER_HOME default to it when they are unset, so a plain shell works; set them to use another toolchain.
# cmake and ninja come from the SDK's cmake package unless the caller already put others first on PATH.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'toolchain-lib.ps1')
Set-ToolchainEnvironment
# Native tools (adb) print UTF-8; a plain pwsh decodes them with the OEM code page (cp437 here) and the phone's labels such as
# "Alpha (middle dot) running" arrive as mojibake, so the label-driven taps in machine-acceptance.ps1 never match.
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Text.UTF8Encoding]::new($false)
$script:HaxeonRoot = Join-Path $script:RepoRoot 'haxeon'
$script:BuildRoot = Join-Path $script:AndroidRoot 'build'
# Where Haxeon keeps its HashLink VM and the CLI's bytecode: its SDK's bin, haxeon/out/sdk/bin (scripts/haxeon_paths.py).
$script:VmDirectory = (& python (Join-Path $script:RepoRoot 'scripts/haxeon_paths.py') $script:HaxeonRoot | Select-Object -First 1)
$script:Hl = Join-Path $script:VmDirectory 'hl.exe'
$script:Cli = Join-Path $script:VmDirectory 'haxeon-cli.hl'

function Get-Tool([string]$name) {
    $found = Get-Command $name -ErrorAction SilentlyContinue
    if (-not $found) { throw "$name is not on PATH" }
    return $found.Source
}

function Assert-Toolchain {
    foreach ($name in 'ANDROID_HOME', 'JAVA_HOME') {
        if (-not (Get-Item "env:$name" -ErrorAction SilentlyContinue)) { throw "$name is not set and the toolchain is not installed: run android/scripts/setup.ps1" }
    }
    $script:Ndk = Join-Path $env:ANDROID_HOME "ndk/$script:NdkVersion"
    if (-not (Test-Path (Join-Path $script:Ndk 'build/cmake/android.toolchain.cmake'))) { throw "NDK $script:NdkVersion is missing under $env:ANDROID_HOME" }
    foreach ($path in 'platforms/android-36', 'build-tools/36.0.0', 'platform-tools') {
        if (-not (Test-Path (Join-Path $env:ANDROID_HOME $path))) { throw "SDK package $path is missing" }
    }
    if (-not (Test-Path (Join-Path $env:JAVA_HOME 'bin/java.exe'))) { throw "JAVA_HOME has no bin/java.exe" }
    $script:Cmake = Get-Tool 'cmake'
    $script:Ninja = Get-Tool 'ninja'
}
