# Shared by run-emulator.ps1, machine-acceptance.ps1 and e2e-local.ps1 (dot-source after env.ps1 and Assert-Toolchain).
# One emulator per console port: the adb serial is emulator-<port>, and every adb call names it.

function Initialize-Emulator([string]$avd, [int]$port) {
    $script:Adb = Join-Path $env:ANDROID_HOME 'platform-tools/adb.exe'
    $script:EmulatorExe = Join-Path $env:ANDROID_HOME 'emulator/emulator.exe'
    $script:AvdName = $avd
    $script:EmulatorPort = $port
    $script:Serial = "emulator-$port"
}

function Invoke-Adb([string]$arguments, [int]$timeout = 60) {
    Invoke-Guarded $script:Adb "-s $script:Serial $arguments" (Join-Path $BuildRoot 'adb.log') $timeout
}

function Save-Screen([string]$path) {
    # adb exec-out writes binary PNG data; capture it with a process redirect rather than the text pipeline.
    $info = [Diagnostics.ProcessStartInfo]::new($script:Adb, "-s $script:Serial exec-out screencap -p")
    $info.RedirectStandardOutput = $true; $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $process = [Diagnostics.Process]::Start($info)
    $file = [IO.File]::Create($path)
    $process.StandardOutput.BaseStream.CopyTo($file); $file.Dispose(); $process.WaitForExit()
    Write-Host "screenshot: $path"
}

function New-EmulatorAvd {
    if (Test-Path (Join-Path $env:ANDROID_AVD_HOME "$script:AvdName.ini")) { return }
    $avdManager = Join-Path $env:ANDROID_HOME 'cmdline-tools/latest/bin/avdmanager.bat'
    Invoke-Guarded $env:ComSpec ('/d /s /c "echo no | "' + $avdManager + '" create avd -n ' + $script:AvdName + ' -k "system-images;android-36;google_apis;x86_64" -d pixel_6 --force"') (Join-Path $BuildRoot 'avd.log') 120
}

# Starts the emulator hidden and waits for boot. Returns the emulator process.
# With -Snapshot the emulator boots from that quick-boot snapshot when it exists (seconds, apps and their data as they were) and
# saves it again when it is stopped with `adb emu kill`; without it nothing is loaded or saved.
function Start-Emulator([string]$gpu = 'swiftshader_indirect', [int]$bootTimeoutSeconds = 240, [string]$snapshot = '') {
    New-EmulatorAvd
    $log = Join-Path $BuildRoot "emulator-$script:EmulatorPort.log"
    $cores = if ($env:EXOSUIT_EMU_CORES) { $env:EXOSUIT_EMU_CORES } else { '2' }
    $memory = if ($env:EXOSUIT_EMU_MEMORY) { $env:EXOSUIT_EMU_MEMORY } else { '3072' }
    $snapshotArguments = if ($snapshot) { @('-snapshot', $snapshot) } else { @('-no-snapshot-save') }
    $emulatorArguments = @('-avd', $script:AvdName, '-port', $script:EmulatorPort, '-no-window', '-no-audio', '-no-boot-anim') + $snapshotArguments + @('-gpu', $gpu, '-cores', $cores, '-memory', $memory)
    $started = Start-Process $script:EmulatorExe -WindowStyle Hidden -PassThru -RedirectStandardOutput $log -RedirectStandardError "$log.err" -ArgumentList $emulatorArguments
    $deadline = (Get-Date).AddSeconds($bootTimeoutSeconds)
    do {
        Start-Sleep -Seconds 3
        $boot = (& $script:Adb -s $script:Serial shell getprop sys.boot_completed 2>$null) -join ''
        if ((Get-Date) -gt $deadline) { Stop-Emulator $started; throw "Emulator did not boot within $bootTimeoutSeconds s; see $log" }
    } until ($boot.Trim() -eq '1')
    return $started
}

function Stop-Emulator($process) {
    & $script:Adb -s $script:Serial emu kill 2>$null | Out-Null
    Start-Sleep -Seconds 3
    if ($process) { Get-Process -Id $process.Id -ErrorAction SilentlyContinue | Stop-Process -Force }
}

# Starts a program hidden as an ordinary child of this process (so it stays inside the caller's job object: nothing escapes a
# guard), with this process's environment plus $extraEnvironment and without CLAUDE* variables, output (both streams) to $log.
# CLAUDE* (CLAUDECODE, CLAUDE_CODE_*, ...) belong to the session that runs the rig, not to the isolated editor: a real claude in a
# rig terminal must behave as on a user's machine. Returns the process of the wrapping cmd.exe.
function Start-Child([string]$exe, [string]$arguments, [string]$log, [hashtable]$extraEnvironment = @{}, [string]$directory = '') {
    if (-not $directory) { $directory = $script:RepoRoot }
    New-Item -ItemType Directory -Force (Split-Path $log -Parent) | Out-Null
    $saved = @{}
    foreach ($variable in Get-ChildItem env:) { if ($variable.Name -like 'CLAUDE*') { $saved[$variable.Name] = $variable.Value } }
    foreach ($key in $extraEnvironment.Keys) { if (-not $saved.ContainsKey($key)) { $saved[$key] = [Environment]::GetEnvironmentVariable($key) } }
    try {
        foreach ($key in @($saved.Keys)) { if ($key -like 'CLAUDE*') { [Environment]::SetEnvironmentVariable($key, $null) } }
        foreach ($key in $extraEnvironment.Keys) { [Environment]::SetEnvironmentVariable($key, [string]$extraEnvironment[$key]) }
        $commandLine = '/d /s /c ""' + $exe + '" ' + $arguments + ' > "' + $log + '" 2>&1"'
        return Start-Process cmd.exe -ArgumentList $commandLine -WindowStyle Hidden -PassThru -WorkingDirectory $directory
    } finally {
        foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key, $saved[$key]) }
    }
}
