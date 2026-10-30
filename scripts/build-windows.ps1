<#
.SYNOPSIS
Builds Exosuit on Windows with the Visual Studio 2026 toolchain.

.DESCRIPTION
Loads the x64 environment of the newest Visual Studio 2026 (18.x) install, puts its
bundled CMake first on PATH, and pins the default CMake generator to Visual Studio 2026.
Then it runs the Haxeon toolchain bootstrap (pinned Haxe, libffi, HashLink, ccache,
Haxeon native) and builds the agent, suit and the graphical app.

The apps' native packages build with Ninja in this environment, through ccache
(Haxeon's NativeCMakeProvider). A build started without it, such as scripts/run.py
from a plain shell, has Haxeon load the newest Visual Studio's environment itself.
The bundled CMake matters for builds that use the default generator: a system CMake
older than 4.2 does not know the 2026 generator and silently falls back to Visual
Studio 2022.

.PARAMETER Clean
Removes every ignored build directory in Exosuit, plus Haxeon's out/ and .tools/,
before building. Benchmark run data is kept. Required after switching toolchains,
because CMake refuses to reuse a build directory made by another generator.

.PARAMETER SkipBootstrap
Skips the Haxeon toolchain bootstrap and only builds the app.

.EXAMPLE
scripts/build-windows.ps1 -Clean
#>
param(
    [switch]$Clean,
    [switch]$SkipBootstrap
)

$ErrorActionPreference = "Stop"
# Remaining arguments go to scripts/build.py.
$BuildArguments = $args

$RootDir = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$HaxeonDir = Join-Path $RootDir "haxeon"

function Enter-VisualStudio2026 {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) {
        throw "vswhere.exe not found; install Visual Studio 2026 with the C++ desktop workload"
    }
    $install = & $vswhere -latest -version "[18.0,19.0)" -products * `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (-not $install) {
        throw "Visual Studio 2026 with the MSVC x64 tools is not installed"
    }

    # vcvars64.bat only changes its own cmd process, so copy the environment it leaves.
    $vcvars = Join-Path $install "VC\Auxiliary\Build\vcvars64.bat"
    $environment = cmd /c "`"$vcvars`" >nul 2>&1 && set"
    if ($LASTEXITCODE -ne 0) { throw "$vcvars failed" }
    foreach ($line in $environment) {
        $separator = $line.IndexOf("=")
        if ($separator -gt 0) {
            [Environment]::SetEnvironmentVariable($line.Substring(0, $separator), $line.Substring($separator + 1))
        }
    }

    $cmakeDir = Join-Path $install "Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin"
    $env:PATH = "$cmakeDir;$env:PATH"
    # Only builds that pick no generator use this, such as the apps' native packages with
    # HAXEON_CMAKE_GENERATOR=default; Haxeon's presets and native packages pick Ninja.
    # CMAKE_GENERATOR_INSTANCE is left unset because it breaks those Ninja configures.
    $env:CMAKE_GENERATOR = "Visual Studio 18 2026"

    Write-Host "Visual Studio $env:VSCMD_VER at $install"
    Write-Host "MSVC $env:VCToolsVersion, $((cmake --version | Select-Object -First 1))"
}

function Remove-BuildOutputs {
    $targets = @(
        git -C $RootDir clean -ndX |
            ForEach-Object { $_ -replace "^Would remove ", "" } |
            Where-Object { $_ -match "(^|/)(build[^/]*|__pycache__|\.ruff_cache)/$" } |
            ForEach-Object { Join-Path $RootDir $_ }
    ) + @((Join-Path $HaxeonDir "out"), (Join-Path $HaxeonDir ".tools"))
    foreach ($target in $targets) {
        if (Test-Path $target) {
            Write-Host "Removing $target"
            Remove-Item -Recurse -Force $target
        }
    }
}

function Invoke-Step([string]$Name, [scriptblock]$Command) {
    Write-Host "== $Name"
    $timer = [Diagnostics.Stopwatch]::StartNew()
    & $Command
    if ($LASTEXITCODE -ne 0) { throw "$Name failed with exit code $LASTEXITCODE" }
    Write-Host "== $Name done in $([int]$timer.Elapsed.TotalSeconds) s"
}

Enter-VisualStudio2026
if ($Clean) {
    Remove-BuildOutputs
}
if (-not $SkipBootstrap) {
    Invoke-Step "Haxeon toolchain bootstrap" { cmake -P (Join-Path $HaxeonDir "cmake/Bootstrap.cmake") }
}
Invoke-Step "Exosuit build" { python (Join-Path $RootDir "scripts/build.py") @BuildArguments }
