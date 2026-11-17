<#
Checks that the Android toolchain is complete and prints what is missing. It installs nothing: set ANDROID_HOME and
JAVA_HOME to a prepared toolchain (see docs/mobile/android.md for the packages).

  pwsh -NoProfile -File android/scripts/bootstrap.ps1
#>
. (Join-Path $PSScriptRoot 'env.ps1')
$problems = @()
foreach ($name in 'ANDROID_HOME', 'JAVA_HOME') {
    if (-not (Get-Item "env:$name" -ErrorAction SilentlyContinue)) { $problems += "$name is not set" }
}
if ($problems.Count -eq 0) {
    $required = @{
        'platform-tools'                                 = 'platform-tools/adb.exe'
        'platforms;android-36'                           = 'platforms/android-36'
        'build-tools;36.0.0'                             = 'build-tools/36.0.0'
        "ndk;$NdkVersion"                                = "ndk/$NdkVersion/build/cmake/android.toolchain.cmake"
        'emulator'                                       = 'emulator'
        'system-images;android-36;google_apis;x86_64'    = 'system-images/android-36/google_apis/x86_64'
    }
    foreach ($package in $required.Keys) {
        if (-not (Test-Path (Join-Path $env:ANDROID_HOME $required[$package]))) { $problems += "SDK package missing: $package" }
    }
    if (-not (Test-Path (Join-Path $env:JAVA_HOME 'bin/java.exe'))) { $problems += 'JAVA_HOME has no bin/java.exe (JDK 21 expected)' }
}
foreach ($tool in 'cmake', 'ninja') {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { $problems += "$tool is not on PATH" }
}
foreach ($path in $Cli, $Hl) {
    if (-not (Test-Path $path)) { $problems += "$path is missing: build haxeon first (scripts/build-windows.ps1)" }
}
if ($problems.Count -gt 0) {
    $problems | ForEach-Object { Write-Host "missing: $_" }
    exit 1
}
Write-Host 'Android toolchain is complete.'
