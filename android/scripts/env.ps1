# Shared by the Android scripts (dot-source it). Reads the toolchain from environment variables; nothing is hard-coded.
#   ANDROID_HOME   Android SDK root (platforms;android-36, build-tools;36.0.0, ndk;30.0.16248370, platform-tools)
#   JAVA_HOME      JDK 21
#   GRADLE_USER_HOME, ANDROID_USER_HOME, ANDROID_AVD_HOME   optional; keep the toolchain state out of the profile
# cmake (3.24+) and ninja must be on PATH.
$ErrorActionPreference = 'Stop'
$script:AndroidRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$script:RepoRoot = (Resolve-Path (Join-Path $script:AndroidRoot '..')).Path
$script:HaxeonRoot = Join-Path $script:RepoRoot 'haxeon'
$script:BuildRoot = Join-Path $script:AndroidRoot 'build'
$script:NdkVersion = '30.0.16248370'
$script:Guard = Join-Path $script:RepoRoot 'docs/benchmarks/perf-harness/run-guarded.ps1'
# Where Haxeon keeps its HashLink VM and the CLI's bytecode (scripts/haxeon_paths.py reads haxeon/cmake/hashlink-output-paths.txt).
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
        if (-not (Get-Item "env:$name" -ErrorAction SilentlyContinue)) { throw "Set $name (see docs/mobile/android.md)" }
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

# Runs a program through the crash-dialog guard (CLAUDE.md); throws on a non-zero exit.
function Invoke-Guarded([string]$exe, [string]$arguments, [string]$log, [int]$timeout, [string]$workingDirectory = $script:RepoRoot) {
    New-Item -ItemType Directory -Force (Split-Path $log -Parent) | Out-Null
    & pwsh -NoProfile -File $script:Guard -TimeoutSeconds $timeout -Exe $exe "-ArgLine:$arguments" -Log $log -WorkingDirectory $workingDirectory
    if ($LASTEXITCODE -ne 0) { throw "$([IO.Path]::GetFileName($exe)) failed with exit code $LASTEXITCODE; see $log" }
}
