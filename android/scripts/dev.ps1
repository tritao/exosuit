<#
Fast edit-to-emulator loop for Haxe-only changes (debug builds).

  pwsh -NoProfile -File android/scripts/dev.ps1 -Serial emulator-5556            # watch: recompile + push + relaunch on each edit
  pwsh -NoProfile -File android/scripts/dev.ps1 -Serial emulator-5556 -Once      # one round, then exit
  pwsh -NoProfile -File android/scripts/dev.ps1 -Serial emulator-5556 -Once -Screenshot out.png
  pwsh -NoProfile -File android/scripts/dev.ps1 -Serial emulator-5556 -Live      # watch: each edit is a live patch, no relaunch
  pwsh -NoProfile -File android/scripts/dev.ps1 -Stop                            # stop the watch loop and the resident compiler

Each round: the haxeon compiler worker (resident between rounds, so only edited code is retyped) recompiles
ui.hl/ui.hli/ui.entries; they are pushed into the app's private files/dev folder, which a debuggable build prefers over
its APK assets (HaxeonRuntime.load); the app is force-stopped and started again. Pairing and credentials live in the app
data and the Keystore, so they survive; the app reconnects to a running rig by itself.

If the non-Haxe sources changed since the last full build (native code, Kotlin, Gradle, native packages; see
Get-NativeStamp), or no APK is installed for this stamp, the script runs build.ps1 and installs the APK instead.
-NoFallback makes that an error. The emulator must already be running (run-emulator.ps1 -KeepRunning).

-Live: the compile is `haxeon build --compiler-only --live` into android/build/haxe-live. The compiler publishes the patch
(main.hl.hlp and the .live.* descriptions) a few seconds after the edit, before it writes the 54 MB module; the script pushes
only the patch into files/dev/patch.hlp and sends the debug intent `live_patch`, and the app applies it in place
(HaxeonRuntime.patch, UiBridge.liveRelease/liveRebuild) and logs `exosuit-live: patched`. The full module is pushed afterwards, off
the critical path, so a restart of the app loads the same revision. When a patch is not possible (the build requires a reload, its base
revision is not the one the phone runs, the runtime refuses it) the script does what plain dev.ps1 does: push the module and relaunch.

The compiler worker keeps its state in android/build/dev/session and exits after -IdleSeconds without a request;
-Stop (or a stop file at android/build/dev/stop, or ending the watch loop) stops it at once. The worker only ever
belongs to this checkout.
#>
param(
    [string]$Serial = 'emulator-5554',
    [switch]$Once,
    [switch]$Stop,
    [string]$Screenshot = '',
    [int]$SettleSeconds = 8,
    [int]$IdleSeconds = 600,
    [switch]$NoFallback,
    [switch]$NoLaunch,
    # Apply each edit as a live patch inside the running app (no relaunch); a patch the runtime cannot take falls back to a reload.
    [switch]$Live
)
. (Join-Path $PSScriptRoot 'env.ps1')
. (Join-Path $PSScriptRoot 'haxe-lib.ps1')
$package = 'com.exosuit.mobile'
$activity = "$package/$package.ExosuitActivity"
$dev = Join-Path $BuildRoot 'dev'
$stopFile = Join-Path $dev 'stop'
$session = Join-Path $dev 'session'
$staged = Join-Path $dev 'assets'
$apk = Join-Path $AndroidRoot 'app/build/outputs/apk/debug/app-debug.apk'
New-Item -ItemType Directory -Force $dev | Out-Null

# The resident workers of this script: state files in the private session directory name their process ids.
function Stop-Workers {
    if (-not (Test-Path $session)) { return }
    foreach ($state in Get-ChildItem $session -Filter '*.json' -ErrorAction SilentlyContinue) {
        try { $id = [int](Get-Content -LiteralPath $state.FullName -Raw | ConvertFrom-Json).pid } catch { continue }
        if ($id -gt 0) {
            $process = Get-Process -Id $id -ErrorAction SilentlyContinue
            # Only a hashlink process whose command line names our session directory.
            if ($process -and $process.ProcessName -like 'hl*') { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue; Write-Host "stopped compiler worker $id" }
        }
        Remove-Item -LiteralPath $state.FullName -Force -ErrorAction SilentlyContinue
    }
}

if ($Stop) {
    New-Item -ItemType File -Force $stopFile | Out-Null   # ends a running watch loop at its next poll
    Stop-Workers
    Write-Host 'stopped'
    exit 0
}
Remove-Item -Force $stopFile -ErrorAction SilentlyContinue

Assert-Toolchain
$adb = Join-Path $env:ANDROID_HOME 'platform-tools/adb.exe'
function Adb([string[]]$arguments) { & $adb -s $Serial @arguments }
if ((Adb 'get-state') -notmatch 'device') { throw "$Serial is not running; start it first (run-emulator.ps1 -KeepRunning)" }

# Everything the compiler worker needs comes from this environment; the worker inherits it.
$env:HAXEON_COMPILER_SESSION_DIR = $session
$env:HAXEON_COMPILER_IDLE_SECONDS = "$IdleSeconds"
# The worker's identity includes PATH, so give it a fixed one: the same worker (and its warm state) must answer every
# round, whichever shell started the script.
$compilePath = (@((Split-Path (Get-Command pwsh).Source), (Join-Path $HaxeonRoot 'out'), $VmDirectory, "$env:SystemRoot\system32", $env:SystemRoot, (Join-Path $env:ANDROID_HOME 'platform-tools'))) -join ';'

function Install-Full {
    if ($NoFallback) { throw 'The non-Haxe sources changed (or no APK is installed); run build.ps1 and install, or drop -NoFallback' }
    Write-Host 'full build (native or host sources changed)...'
    # The device decides the ABI: an x86_64-only APK does not install on an arm64 phone.
    $abi = ((Adb @('shell', 'getprop', 'ro.product.cpu.abi')) | Out-String).Trim()
    if ($abi -notin 'x86_64', 'arm64-v8a') { throw "Unsupported device ABI '$abi' on $Serial" }
    & (Join-Path $PSScriptRoot 'build.ps1') -Abi $abi
    if ($LASTEXITCODE -ne 0) { throw 'Android build failed' }
    Adb @('install', '-r', $apk) | Out-Host
    Adb @('shell', 'run-as', $package, 'rm', '-rf', 'files/dev') | Out-Null
    Remove-Item -Force (Join-Path $dev "live-state-$Serial.json") -ErrorAction SilentlyContinue   # a new install runs the APK's module
    $script:installedStamp = Get-NativeStamp
    [IO.File]::WriteAllText((Join-Path $dev "installed-$Serial.stamp"), $script:installedStamp)
}

function Test-ApkCurrent {
    $recorded = Join-Path $dev "installed-$Serial.stamp"
    if (-not (Test-Path $recorded)) {
        # build.ps1 wrote native.stamp for the APK it built; trust it only if this device has that APK installed.
        $built = Join-Path $BuildRoot 'native.stamp'
        if (-not (Test-Path $built) -or -not (Test-Path $apk)) { return $false }
        if (-not ((Adb @('shell', 'pm', 'list', 'packages', $package)) -match $package)) { return $false }
        [IO.File]::WriteAllText($recorded, (Get-Content -LiteralPath $built -Raw).Trim())
    }
    return (Get-Content -LiteralPath $recorded -Raw).Trim() -eq (Get-NativeStamp)
}

$pushed = @{}
function Push-Module {
    $remote = '/data/local/tmp/exosuit-dev'
    Adb @('shell', 'mkdir', '-p', $remote) | Out-Null
    foreach ($name in 'ui.hl', 'ui.hli', 'ui.entries') {
        $local = Join-Path $staged $name
        $hash = (Get-FileHash $local -Algorithm SHA1).Hash
        if ($pushed[$name] -eq $hash) { continue }
        Adb @('push', $local, "$remote/$name") | Out-Null
        $pushed[$name] = $hash
    }
    # run-as copies into the app's private files/dev (debug builds only; a release build has no run-as and ignores the folder).
    $copy = "mkdir -p files/dev && cp $remote/ui.hl $remote/ui.hli $remote/ui.entries files/dev/"
    $result = Adb @('shell', 'run-as', $package, 'sh', '-c', "'$copy'")
    if ($LASTEXITCODE -ne 0) { throw "run-as failed (is the installed APK a debug build?): $result" }
}


# ---- -Live: patches instead of relaunches -------------------------------------------------------------------------------
$liveOut = Join-Path $BuildRoot 'haxe-live'
$liveStaged = Join-Path $dev 'assets-live'
$liveState = Join-Path $dev "live-state-$Serial.json"
$liveModule = Join-Path $liveOut 'output/host/main.hl'
if ($Live) { $staged = $liveStaged }

function Read-LiveState { if (Test-Path $liveState) { try { return Get-Content -LiteralPath $liveState -Raw | ConvertFrom-Json } catch {} } return $null }
function Save-LiveState([string]$identity, [int]$revision) {
    [IO.File]::WriteAllText($liveState, (@{ identity = $identity; revision = $revision } | ConvertTo-Json))
}
function Read-Stamp { try { return [IO.File]::ReadAllText("$liveModule.live.stamp").Trim() } catch { return $null } }

function Start-LiveCompile {
    $projectPath = Write-HaxeProject $liveOut
    $env:HAXEON_HOME = $HaxeonRoot
    $info = [Diagnostics.ProcessStartInfo]::new((Get-Command pwsh).Source)
    $compileArguments = '"' + $Cli + '" build --compiler-only --live --project "' + $projectPath + '"'
    foreach ($argument in '-NoProfile', '-File', $script:Guard, '-TimeoutSeconds', '900', '-Exe', $Hl, "-ArgLine:$compileArguments",
        '-Log', (Join-Path $liveOut 'compile.log'), '-WorkingDirectory', $RepoRoot) { $info.ArgumentList.Add($argument) }
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $savedPath = $env:PATH; $env:PATH = $compilePath
    try { return [Diagnostics.Process]::Start($info) } finally { $env:PATH = $savedPath }
}

# Pushes the HLP and asks the app to apply it; true when the app logged success.
function Send-LivePatch([string]$hlp) {
    $remote = '/data/local/tmp/exosuit-dev'
    Adb @('shell', 'mkdir', '-p', $remote) | Out-Null
    Adb @('push', $hlp, "$remote/patch.hlp") | Out-Null
    Adb @('shell', 'run-as', $package, 'sh', '-c', "'mkdir -p files/dev && cp $remote/patch.hlp files/dev/patch.hlp'") | Out-Null
    Adb @('logcat', '-c') | Out-Null
    Adb @('shell', 'am', 'start', '-n', $activity, '--ez', 'live_patch', 'true') | Out-Null
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline) {
        $text = (Adb @('logcat', '-d', '-s', 'ExosuitLive:I', 'ExosuitJNI:E')) -join "`n"
        if ($text -match 'exosuit-live: patched in (\d+) ms') { return $true }
        if ($text -match 'exosuit-live: refused') { Write-Host $text; return $false }
        Start-Sleep -Milliseconds 100
    }
    return $false
}

function Invoke-LiveRound($editTicks = $null) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $before = Read-Stamp
    $state = Read-LiveState
    $running = ((Adb @('shell', 'pidof', $package)) -join '').Trim() -ne ''
    $process = Start-LiveCompile
    $patched = $false; $patchSeconds = 0.0; $attempted = $false
    while (-not $process.HasExited) {
        Start-Sleep -Milliseconds 80
        $stamp = Read-Stamp
        if ($attempted -or -not $stamp -or $stamp -eq $before) { continue }
        $attempted = $true
        # The stamp is written after the patch and its descriptions.
        $summary = Get-Content -LiteralPath "$liveModule.live.patch.json" -Raw | ConvertFrom-Json
        $why = if (-not $running) { 'the app is not running' } elseif (-not $state) { 'no known phone revision' }
            elseif ($summary.requiresReload) { 'the build requires a reload' } elseif (-not $summary.patchAvailable) { 'the build carries no patch' }
            elseif ($summary.moduleIdentity -ne $state.identity) { 'another module' }
            elseif ([int]$summary.baseRevision -ne [int]$state.revision) { "patch base $($summary.baseRevision) is not the phone's revision $($state.revision)" } else { '' }
        if ($why -eq '') {
            $patched = Send-LivePatch "$liveModule.hlp"
            $patchSeconds = $timer.Elapsed.TotalSeconds
            if ($patched) {
                Save-LiveState $summary.moduleIdentity ([int]$summary.revision)
                $afterSave = ''
                if ($editTicks) { $afterSave = ', {0:N1} s after the save' -f (((Get-Date).ToUniversalTime() - [DateTime]::new([long]$editTicks, 'Utc')).TotalSeconds) }
                Write-Host ('live patch: revision {0} applied {1:N1} s after the compile started{2}' -f $summary.revision, $patchSeconds, $afterSave)
            } else { Write-Host 'live patch refused or not applied; will reload' }
        } else { Write-Host "no live patch for revision $($summary.revision): $why" }
    }
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) { Write-Host "compile failed (exit $($process.ExitCode)); see $liveOut\compile.log"; return }
    $compiled = $timer.Elapsed.TotalSeconds
    Publish-HaxeModule $liveOut $liveStaged
    Push-Module
    $description = Get-Content -LiteralPath "$liveModule.live.json" -Raw | ConvertFrom-Json
    if (-not $patched) {
        if (-not $NoLaunch) {
            Adb @('shell', 'am', 'force-stop', $package) | Out-Null
            Adb @('logcat', '-c') | Out-Null
            Adb @('shell', 'am', 'start', '-n', $activity) | Out-Null
        }
        Write-Host ('reload round: compile {0:N1} s, total {1:N1} s' -f $compiled, $timer.Elapsed.TotalSeconds)
    } else {
        Write-Host ('patch round: patched at {0:N1} s; full module written and pushed by {1:N1} s' -f $patchSeconds, $timer.Elapsed.TotalSeconds)
    }
    Save-LiveState $description.moduleIdentity ([int]$description.revision)
    if ($Screenshot) { Start-Sleep -Seconds $(if ($patched) { 1 } else { $SettleSeconds }); Save-Screen $Screenshot }
}


function Invoke-Round {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $savedPath = $env:PATH; $env:PATH = $compilePath
    try { Invoke-HaxeCompile (Join-Path $BuildRoot 'haxe') $staged } finally { $env:PATH = $savedPath }
    $compiled = $timer.Elapsed.TotalSeconds
    Push-Module
    $pushedAt = $timer.Elapsed.TotalSeconds
    if (-not $NoLaunch) {
        Adb @('shell', 'am', 'force-stop', $package) | Out-Null
        Adb @('logcat', '-c') | Out-Null
        Adb @('shell', 'am', 'start', '-n', $activity) | Out-Null
    }
    $launched = $timer.Elapsed.TotalSeconds
    if ($Screenshot -and -not $NoLaunch) {
        Start-Sleep -Seconds $SettleSeconds
        Save-Screen $Screenshot
    }
    Write-Host ('round: compile {0:N1} s, push {1:N1} s, relaunch {2:N1} s, total {3:N1} s (to screenshot {4:N1} s)' -f $compiled, ($pushedAt - $compiled), ($launched - $pushedAt), $launched, $timer.Elapsed.TotalSeconds)
}

# Save-Screen is shared with the other scripts.
. (Join-Path $PSScriptRoot 'emulator-lib.ps1')
Initialize-Emulator 'unused' ([int]($Serial -replace '\D', ''))

try {
    if (-not (Test-ApkCurrent)) { Install-Full }
    if ($Live) { Invoke-LiveRound } else { Invoke-Round }
    if (-not $Once) {
        # Poll the Haxe roots; a round starts half a second after the last change so a save burst is one round.
        $roots = @((Join-Path $AndroidRoot 'haxe/src'), (Join-Path $RepoRoot 'src'), (Join-Path $RepoRoot 'graphical/src'),
            (Join-Path $HaxeonRoot 'packages'), (Join-Path $RepoRoot 'native-packages'))
        function Get-Newest {
            $newest = 0L
            foreach ($root in $roots) {
                foreach ($path in [IO.Directory]::EnumerateFiles($root, '*.hx', [IO.SearchOption]::AllDirectories)) {
                    $ticks = [IO.File]::GetLastWriteTimeUtc($path).Ticks
                    if ($ticks -gt $newest) { $newest = $ticks }
                }
            }
            return $newest
        }
        $seen = Get-Newest
        Write-Host "watching for edits; stop with: dev.ps1 -Stop (or Ctrl+C)"
        while (-not (Test-Path $stopFile)) {
            Start-Sleep -Milliseconds 700
            $now = Get-Newest
            if ($now -le $seen) { continue }
            Start-Sleep -Milliseconds 500
            $seen = Get-Newest
            try {
                if (-not (Test-ApkCurrent)) { Install-Full }
                if ($Live) { Invoke-LiveRound $seen } else { Invoke-Round }
            } catch { Write-Host "round failed: $_" }   # a compile error keeps the loop alive for the next edit
        }
    }
} finally {
    if (-not $Once) { Stop-Workers; Remove-Item -Force $stopFile -ErrorAction SilentlyContinue }
}
