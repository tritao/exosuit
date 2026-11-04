<#
Runs the app on a headless x86_64 emulator and saves a screenshot.

  pwsh -NoProfile -File android/scripts/run-emulator.ps1 [-Avd exosuit-x86_64] [-Gpu swiftshader_indirect]
      [-Port 5554] [-Screenshot out.png] [-Tap "x,y"] [-KeepRunning]

Creates the AVD on first use (system-images;android-36;google_apis;x86_64), starts it without a window, waits for
boot, installs the debug APK, launches it, waits for frames, writes the screenshot (and a second one after -Tap), and
stops the emulator unless -KeepRunning is given. Logs: <build>/emulator.log, <build>/logcat.txt.
#>
param(
    [string]$Avd = 'exosuit-x86_64',
    [int]$Port = 5554,
    [string]$Gpu = 'swiftshader_indirect',
    [string]$Screenshot = '',
    [string]$Tap = '',
    [int]$Port = 5554,
    [int]$BootTimeoutSeconds = 240,
    [int]$StartupSeconds = 25,
    [switch]$KeepRunning
)
. (Join-Path $PSScriptRoot 'env.ps1')
. (Join-Path $PSScriptRoot 'emulator-lib.ps1')
Assert-Toolchain
Initialize-Emulator $Avd $Port
$apk = Join-Path $AndroidRoot 'app/build/outputs/apk/debug/app-debug.apk'
if (-not (Test-Path $apk)) { throw "Build the APK first: $apk" }
if (-not $Screenshot) { $Screenshot = Join-Path $BuildRoot 'screenshot.png' }
New-Item -ItemType Directory -Force $BuildRoot | Out-Null

$started = Start-Emulator $Gpu $BootTimeoutSeconds
try {
    Invoke-Adb "install -r `"$apk`"" 180
    Invoke-Adb 'logcat -c'
    Invoke-Adb 'shell am start -S -n com.exosuit.mobile/.ExosuitActivity'
    Start-Sleep -Seconds $StartupSeconds
    Save-Screen $Screenshot
    if ($Tap) {
        $x, $y = $Tap.Split(',')
        Invoke-Adb "shell input tap $x $y"
        Start-Sleep -Seconds 3
        Save-Screen ([IO.Path]::ChangeExtension($Screenshot, $null).TrimEnd('.') + '-after-tap.png')
    }
    & $script:Adb -s $script:Serial logcat -d | Set-Content (Join-Path $BuildRoot 'logcat.txt')
} finally {
    if (-not $KeepRunning) { Stop-Emulator $started }
}

exit 0
