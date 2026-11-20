<#
The whole product on this machine, end to end, with no cloud account and nothing shared with the real editor, exohost or
relay: a local relay Worker (wrangler dev) behind a locally generated CA, an isolated desktop (exohost, workspace service
and the real graphical editor, running in live mode) and the Android app on a headless emulator, paired through the
editor's Remote Access panel. docs/mobile/e2e-local.md explains the pieces.

The rig is persistent. You pair once; every later `up` resumes in seconds with the same relay (CA, certificates, ports,
Durable Object state), the same editor state (machine identity, paired devices, workspaces Alpha/Beta) and the same phone
(app data and Keystore untouched, emulator quick-boot snapshot), so nothing is paired, cleared or reinstalled again.

  pwsh -NoProfile -File scripts/e2e-local.ps1 up              # (background, blocks) the keeper: start (or resume) relay, editor in --live mode, emulator, app, then block until down
  pwsh -NoProfile -File scripts/e2e-local.ps1 pair            # one time: pair the phone (skipped when already paired)
  pwsh -NoProfile -File scripts/e2e-local.ps1 step -Step session   # run ONE step (or a list: -Step session,terminal) against the running rig
  pwsh -NoProfile -File scripts/e2e-local.ps1 status          # what is running
  pwsh -NoProfile -File scripts/e2e-local.ps1 down            # stop everything; keeps all data and saves the emulator snapshot
  pwsh -NoProfile -File scripts/e2e-local.ps1 reset           # down and delete the rig's data (the next up and pair start over)
  pwsh -NoProfile -File scripts/e2e-local.ps1 run             # the final gate: reset, up, pair, every step, down (also on failure)

Steps (gui_scenarios/e2e_pair.py): pair, session (open Alpha, send a prompt), terminal (Claude Code terminal), beta (grant
Beta). Each step sets up only its own preconditions and fails with a plain message when the rig is not paired.

`up` is the keeper: it starts the relay, the editor and the emulator as ordinary children (inside the caller's job object,
nothing escapes a guard), writes <RunDir>\state.json, and then BLOCKS until <RunDir>\down appears, when it stops them cleanly
and saves the emulator snapshot. Run it ONCE in the background (e.g. wt-run.ps1 with a long timeout, run_in_background);
`pair`, `step` and `status` talk to the rig it keeps alive; `down` creates the down file and waits for the keeper to exit.
Children get this process's environment without CLAUDE* variables, so a real claude in a rig terminal behaves as on a user's
machine. `up -Restart` on a running rig relaunches the app and measures the time to "machine online".

  -Build      build what is missing first (desktop apps, admin tool, APK)
  -Avd/-Port  the emulator (default exosuit-mobile-e2e on 5556)
  -RunDir     the rig's folder (default <repo>\.local\rig, git-ignored): keys, state, logs, screenshots
  -Prompt     what the phone sends
  -Snapshot   the emulator quick-boot snapshot (default rig)

Screenshots (look at them) land in <RunDir>\screens: editor-*.png (the editor window, PrintWindow) and phone-*.png.
Exit 0 when every step passed.
#>
param(
    [Parameter(Mandatory, Position = 0)][ValidateSet('up', 'pair', 'step', 'status', 'down', 'reset', 'run')][string]$Command,
    [string[]]$Step = @(),
    [string]$Avd = 'exosuit-mobile-e2e',
    [int]$Port = 5556,
    [string]$RunDir = '',
    [string]$Prompt = 'hello from the phone',
    [string]$SessionName = 'Fake session',
    [string]$Snapshot = 'rig',
    [switch]$Build,
    [switch]$Restart,
    # Use this relay instead of starting a local Worker, CA and TLS front (e.g. your deployed Worker, docs/mobile/own-relay.md).
    [string]$RelayUrl = ''
)
. (Join-Path $PSScriptRoot '..\android\scripts\env.ps1')
. (Join-Path $PSScriptRoot '..\android\scripts\emulator-lib.ps1')
if (-not $RunDir) { $RunDir = Join-Path $RepoRoot '.local\rig' }
New-Item -ItemType Directory -Force $RunDir | Out-Null
$RunDir = (Resolve-Path $RunDir).Path
$hostDir = Join-Path $RunDir 'host'
$editorDir = Join-Path $RunDir 'editor'
$screens = Join-Path $RunDir 'screens'
$configPath = Join-Path $RunDir 'config.json'
$statePath = Join-Path $RunDir 'state.json'
$downPath = Join-Path $RunDir 'down'
$pairedPath = Join-Path $RunDir 'paired.json'
$python = (Get-Command python -ErrorAction Stop).Source
$hostScript = Join-Path $RepoRoot 'scripts\e2e-local-host.py'
$harness = Join-Path $RepoRoot 'docs\benchmarks\perf-harness'
$apk = Join-Path $AndroidRoot 'app\build\outputs\apk\debug\app-debug.apk'
$package = 'com.exosuit.mobile'
$activity = "$package/$package.ExosuitActivity"
$admin = Join-Path $RepoRoot 'tests\mobile-pairing\build\host\main.hl'
function Say([string]$text) { Write-Host ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $text) }
function Adb { & $script:Adb -s $script:Serial @args }
function Read-State { if (Test-Path $statePath) { try { return Get-Content $statePath -Raw | ConvertFrom-Json -AsHashtable } catch {} } return @{} }
function Save-State($state) { $state | ConvertTo-Json | Set-Content $statePath }
function Test-Alive($id) { return $id -and [bool](Get-Process -Id ([int]$id) -ErrorAction SilentlyContinue) }
function Test-Listening([int]$port) {
    try { $client = [Net.Sockets.TcpClient]::new(); $client.Connect('127.0.0.1', $port); $client.Dispose(); return $true } catch { return $false }
}
function Wait-Log([string]$pattern, [int]$seconds) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        $match = [regex]::Match(((Adb logcat -d) -join "`n"), $pattern)
        if ($match.Success) { return $match.Value }
        Start-Sleep -Milliseconds 250
    }
    throw "Timed out after $seconds s waiting for '$pattern' in the phone's log"
}

function Invoke-Build {
    Say 'building the desktop apps, the admin tool and the APK'
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'build-windows.ps1') -SkipBootstrap
    if ($LASTEXITCODE -ne 0) { throw 'desktop build failed' }
    & $python (Join-Path $RepoRoot 'scripts\haxeon_cli.py') build --project (Join-Path $RepoRoot 'tests\mobile-pairing\haxeon.json')
    if ($LASTEXITCODE -ne 0) { throw 'admin tool build failed' }
    & (Join-Path $AndroidRoot 'scripts\build.ps1') -Abi x86_64
    if ($LASTEXITCODE -ne 0) { throw 'Android build failed' }
}

function Assert-Built {
    $missing = @()
    foreach ($path in $apk, $admin, (Join-Path $RepoRoot 'graphical\build\host\main.hl'), (Join-Path $RepoRoot 'exohost\build\host\main.hl'),
        (Join-Path $RepoRoot 'agent\build\host\main.hl')) {
        if (-not (Test-Path $path)) { $missing += $path }
    }
    if ($missing) { throw "Not built: $($missing -join ', '). Run with -Build." }
}

# ---- the relay side ---------------------------------------------------------------------------------------------------
function Start-Relay {
    if ($RelayUrl) {
        # A real relay: public certificate on both sides, so no local Worker, CA, TLS front or adb reverse.
        return [pscustomobject]@{ relayOrigin = $RelayUrl.TrimEnd('/'); tlsOrigin = $RelayUrl.TrimEnd('/'); tlsPort = 0; ca = '' }
    }
    $wrangler = Join-Path $RepoRoot 'relay\worker\node_modules\wrangler\bin\wrangler.js'
    if (-not (Test-Path $wrangler)) {
        Say 'npm ci in relay/worker (the repo''s pinned wrangler)'
        Push-Location (Join-Path $RepoRoot 'relay\worker'); try { & npm ci --no-audit --no-fund; if ($LASTEXITCODE -ne 0) { throw 'npm ci failed' } } finally { Pop-Location }
    }
    $ready = Join-Path $hostDir 'ready.json'
    if (Test-Path $ready) {
        $info = Get-Content $ready -Raw | ConvertFrom-Json
        if (Test-Listening $info.tlsPort) { Say "relay already running (ports $($info.relayPort), $($info.tlsPort))"; return $info }
        Remove-Item $ready -Force
    }
    Say 'starting the relay (wrangler dev) and the TLS front; CA, certificates, ports and relay state are kept between runs'
    New-Item -ItemType Directory -Force $hostDir | Out-Null
    $process = Start-Child $python "`"$hostScript`" start --out `"$hostDir`" --lifetime 0" (Join-Path $RunDir 'host-start.log')
    $state = Read-State; $state.host = $process.Id; Save-State $state
    $deadline = (Get-Date).AddSeconds(150)
    while (-not (Test-Path $ready)) {
        if ((Get-Date) -gt $deadline -or -not (Test-Alive $process.Id)) { throw "The relay did not become ready; see $RunDir\host-start.log and $hostDir" }
        Start-Sleep -Milliseconds 500
    }
    return Get-Content $ready -Raw | ConvertFrom-Json
}

# ---- configuration the scenario reads ----------------------------------------------------------------------------------
function Write-Config($info) {
    $fake = Join-Path $RepoRoot 'tests\workspace-agents\fake-codex.py'
    $config = [ordered]@{
        root = $RepoRoot; adb = $script:Adb; serial = $script:Serial; activity = $activity; admin = $admin; sessionName = $SessionName
        relayOrigin = $info.relayOrigin; tlsOrigin = $info.tlsOrigin; tlsPort = $info.tlsPort; ca = $info.ca; prompt = $Prompt
        screens = $screens
        fakeClaudeLog = (Join-Path $RunDir 'fake-claude.log')
        editorEnv = [ordered]@{
            EXOSUIT_RELAY_ALLOW_LOOPBACK_HTTP = '1'
            EXOSUIT_RELAY_TEST_CREDENTIALS_DIR = (Join-Path $RunDir 'credentials')
            EXOSUIT_CODEX_BIN = $python; EXOSUIT_CODEX_SCRIPT = $fake
            EXOSUIT_CODEX_PROXY_LAUNCHER = (Join-Path $RepoRoot 'scripts\run-codex-proxy.py')
            FAKE_CODEX_REPLY = '1'; EXOSUIT_SERVICE_IDLE_SECONDS = '3000'
            EXOSUIT_CLAUDE_BIN = $python; EXOSUIT_CLAUDE_SCRIPT = (Join-Path $RepoRoot 'tests\workspace-terminals\fake-claude-tui.py')
            FAKE_CLAUDE_LOG = (Join-Path $RunDir 'fake-claude.log'); PYTHONIOENCODING = 'utf-8'
        }
    }
    $config | ConvertTo-Json -Depth 5 | Set-Content $configPath
}

# ---- the editor: isolated state kept in <RunDir>\editor, running `scripts/run.py --live` ---------------------------------------
function Get-EditorProcess {
    $pattern = [regex]::Escape(($RepoRoot -replace '\\', '/')) + '/graphical/build[^/]*/host/'
    Get-CimInstance Win32_Process -Filter "Name='hl.exe'" | Where-Object {
        $_.CommandLine -and ($_.CommandLine -replace '\\', '/') -match $pattern -and $_.CommandLine -notmatch 'haxeon[\\/]compiler|--output' } |
        Select-Object -First 1
}

function Start-Editor {
    $state = Read-State
    if (Test-Alive $state.editorPid) { Say "editor already running (pid $($state.editorPid))"; return }
    $envFile = Join-Path $editorDir 'ENV.json'
    $env:EXOSUIT_E2E_CONFIG = $configPath
    if (-not (Test-Path $envFile)) {
        Say 'first start: creating the editor''s isolated state (exohost, workspaces Alpha and Beta)'
        New-Item -ItemType Directory -Force $editorDir | Out-Null
        & $python -I (Join-Path $harness 'gui_fixture.py') --root $RepoRoot --out $editorDir --scenario e2e_pair
        if ($LASTEXITCODE -ne 0) { throw 'the fixture failed' }
    }
    $cfg = Get-Content $envFile -Raw | ConvertFrom-Json
    $extra = @{ EXOSUIT_E2E_CONFIG = $configPath; EXOSUIT_EXOHOST_IDLE_SECONDS = '86400' }
    foreach ($property in $cfg.env.PSObject.Properties) { if (-not $extra.ContainsKey($property.Name)) { $extra[$property.Name] = $property.Value } }
    Say 'starting the editor in live mode (scripts/run.py --live)'
    $arguments = '"' + (Join-Path $RepoRoot 'scripts\run.py') + '" --live ' + ((@($cfg.appArgs) + @($cfg.open) | Where-Object { $_ } | ForEach-Object { '"' + $_ + '"' }) -join ' ')
    $launcher = Start-Child $python $arguments (Join-Path $RunDir 'editor.log') $extra $RepoRoot
    $state.editorLauncher = $launcher.Id
    Save-State $state
    # Ready once the window has linked to the rig's exohost (exosuitctl list names its process).
    $deadline = (Get-Date).AddSeconds(600)
    $editor = $null
    $ready = $false
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 1
        if (-not $editor) { $editor = Get-EditorProcess }
        if ($editor -and (Get-EditorInstance ([int]$editor.ProcessId))) { $ready = $true; break }
        if (-not (Test-Alive $launcher.Id) -and -not $editor) { throw "The editor did not start; see $RunDir\editor.log" }
    }
    if (-not $ready) { throw "The editor was not ready after 600 s; see $RunDir\editor.log" }
    $state.editorPid = [int]$editor.ProcessId
    Save-State $state
    Say "editor ready (pid $($editor.ProcessId))"
}

# ---- the phone --------------------------------------------------------------------------------------------------------------
function Start-Phone($info) {
    $state = Read-State
    $running = ((& $script:Adb devices) -join "`n") -match "$script:Serial\s+device"
    if (-not $running) {
        Say "starting the emulator from snapshot '$Snapshot' (a cold boot the first time)"
        $emulator = Start-Emulator $(if ($env:EXOSUIT_EMU_GPU) { $env:EXOSUIT_EMU_GPU } else { 'swiftshader_indirect' }) 240 $Snapshot
        $state.emulator = $emulator.Id
        Save-State $state
    } else { Say 'emulator already running' }
    $installed = ((Adb shell pm list packages $package) -join '') -match $package
    $hash = (Get-FileHash $apk -Algorithm SHA1).Hash
    if (-not $installed -or $state.apkHash -ne $hash) {
        Say 'installing the APK (install -r keeps the app''s data)'
        Adb install -r $apk | Out-Null
        $state.apkHash = $hash
        Save-State $state
    }
    if (-not $RelayUrl) {
        Adb reverse "tcp:$($info.tlsPort)" "tcp:$($info.tlsPort)" | Out-Null
        if (((Adb shell run-as $package ls files) -join ' ') -notmatch 'dev-ca.pem') {
            Adb push $info.ca /data/local/tmp/dev-ca.pem | Out-Null
            Adb shell run-as $package mkdir -p files | Out-Null
            Adb shell run-as $package cp /data/local/tmp/dev-ca.pem files/dev-ca.pem | Out-Null
            Adb shell rm /data/local/tmp/dev-ca.pem | Out-Null
            if (((Adb shell run-as $package ls files) -join ' ') -notmatch 'dev-ca.pem') { throw 'The development CA did not reach the app''s files' }
        }
    }
    # The app's automation snapshot and its test-rig intent extras (pairing_url) need files/automation.on, read at launch.
    # It stays for as long as the rig is up (steps run against it); Stop-Rig removes it, and every `up` puts it back.
    Adb shell run-as $package mkdir -p files | Out-Null
    Adb shell run-as $package touch files/automation.on | Out-Null
}

# Starts the app when it is not running (or with -Restart) and measures the time until it lists the machine's workspaces.
function Start-App {
    $running = ((Adb shell pidof $package) -join '').Trim() -ne ''
    if ($running -and -not $Restart) { Say 'app already running (resumed from the snapshot)'; return }
    if ($running) { Adb shell am force-stop $package | Out-Null }
    Adb logcat -c | Out-Null
    $timer = [Diagnostics.Stopwatch]::StartNew()
    Adb shell am start -n $activity | Out-Null
    # An unpaired phone has no machine to list: the first `up` after a reset only starts the app, `pair` follows.
    if (-not (Test-Path $pairedPath)) { Say 'app started (not paired yet: no machine to wait for)'; return }
    $line = Wait-Log 'exosuit-machine: \S.* online \[[^\]]+\]' 60
    Say ("app launch to workspaces listed: {0:N1} s ({1})" -f $timer.Elapsed.TotalSeconds, $line)
}

# exosuitctl against the rig's exohost (its EXOSUIT_EXOHOST_HOME from the fixture): the output, or $null when it failed.
function Invoke-ExosuitCtl([string[]]$Arguments) {
    $cfg = Get-Content (Join-Path $editorDir 'ENV.json') -Raw | ConvertFrom-Json
    $saved = $env:EXOSUIT_EXOHOST_HOME
    try {
        $env:EXOSUIT_EXOHOST_HOME = $cfg.env.EXOSUIT_EXOHOST_HOME
        $output = & $python -I (Join-Path $RepoRoot 'scripts\exohost.py') --ctl @Arguments 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        return ($output -join "`n")
    } finally { $env:EXOSUIT_EXOHOST_HOME = $saved }
}

# The window id exohost knows the editor process `$ProcessId` by, or $null while it has not linked.
function Get-EditorInstance([int]$ProcessId) {
    $listed = Invoke-ExosuitCtl @('--output', 'json', 'list')
    if (-not $listed) { return $null }
    $found = @(($listed | ConvertFrom-Json).instances | Where-Object { $_.pid -eq $ProcessId })
    if ($found.Count -eq 0) { return $null }
    return $found[0].instance_id
}

# A real editor restart, for the `restart-editor` step: asks the editor to quit the way closing its window does
# (`exosuitctl quit --mode prompt`, no mouse),
# waits for the process to go, then starts the editor again exactly as `up` does. The request and the answer are files in the
# run folder; the answer holds the epoch seconds of the close and of the moment the editor was ready again.
function Restart-Editor {
    $state = Read-State
    $closed = $null
    $editor = $null
    if ([int]$state.editorPid -gt 0) { $editor = Get-Process -Id ([int]$state.editorPid) -ErrorAction SilentlyContinue }
    if ($editor) {
        $instance = Get-EditorInstance $editor.Id
        if ($instance) { Invoke-ExosuitCtl @('--instance', $instance, '--timeout', '20', 'quit', '--mode', 'prompt') | Out-Null }
        if (-not $editor.WaitForExit(20000)) { Say 'the editor did not quit in 20 s; ending it'; $editor.Kill() }
    }
    $closed = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() / 1000.0
    if (Test-Alive $state.editorLauncher) { & taskkill /T /F /PID $state.editorLauncher 2>&1 | Out-Null }
    # The launcher's resident compiler worker and live host belong to the old watch session; a new launcher cannot reuse them.
    # The exohost and the workspace services stay up, as they do when a user closes the window.
    $root = ($RepoRoot -replace '\\', '/')
    Get-CimInstance Win32_Process -Filter "Name='hl.exe'" | Where-Object {
        $_.CommandLine -and ($_.CommandLine -replace '\\', '/').Contains($root) -and ($_.CommandLine -replace '\\', '/') -notmatch 'exohost/build|agent/build' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    $state.editorPid = 0
    Save-State $state
    try { Start-Editor } catch { throw ("$_ -- the editor log ends: " + ((Get-Content (Join-Path $RunDir 'editor.log') -Tail 6 -ErrorAction SilentlyContinue) -join ' | ')) }
    $ready = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() / 1000.0
    return @{ closed = $closed; ready = $ready }
}

# Brings everything up as children of this process, then (with -Keep) stays alive until `down` is asked for. The rig lives
# exactly as long as this process: run it once in the background (a guard's job object is respected, nothing escapes it).
function Up([switch]$Keep) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    Assert-Toolchain
    Initialize-Emulator $Avd $Port
    $state = Read-State
    if ($Keep -and (Test-Alive $state.keeper) -and $state.keeper -ne $PID) {
        Say "the rig is already up (keeper pid $($state.keeper))"
        if ($Restart) { Start-App }
        return
    }
    if ($Build) { Invoke-Build }
    Assert-Built
    Remove-Item $downPath -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $screens, (Join-Path $RunDir 'credentials') | Out-Null
    $state = @{ apkHash = $state.apkHash; keeper = $PID; ready = $false }
    Save-State $state
    try {
        $info = Start-Relay
        Say "relay: desktop $($info.relayOrigin), phone $($info.tlsOrigin)"
        Write-Config $info
        Start-Editor
        Start-Phone $info
        Start-App
        $state = Read-State; $state.ready = $true; Save-State $state
        Say ("up in {0:N1} s ({1})" -f $timer.Elapsed.TotalSeconds, $(if (Test-Path $pairedPath) { 'paired' } else { 'not paired yet: run pair' }))
        if ($Keep) {
            Say 'rig ready; keeping it up until `down` (or until this process is ended)'
            $restartRequest = Join-Path $RunDir 'restart-editor'
            while (-not (Test-Path $downPath)) {
                if (Test-Path $restartRequest) {
                    Remove-Item $restartRequest -Force
                    $answer = $null
                    try { $answer = Restart-Editor } catch { $answer = @{ error = "$_" } }
                    $answer | ConvertTo-Json | Set-Content (Join-Path $RunDir 'restart-editor.done')
                }
                Start-Sleep -Milliseconds 500
            }
        }
    } finally {
        if ($Keep) { Stop-Rig }
    }
}

# ---- steps ---------------------------------------------------------------------------------------------------------------------
function Invoke-Steps([string[]]$names) {
    if (-not (Test-Path $configPath)) { throw 'Run `up` first.' }
    $state = Read-State
    if (-not ($state.ready -and (Test-Alive $state.keeper) -and (Test-Alive $state.editorPid))) { throw 'The rig is not up: run `up` once in the background (it stays alive until `down`).' }
    Initialize-Emulator $Avd $Port
    $env:EXOSUIT_E2E_CONFIG = $configPath
    $env:EXOSUIT_E2E_STEPS = ($names -join ',')
    $cfg = Get-Content (Join-Path $editorDir 'ENV.json') -Raw | ConvertFrom-Json
    # The scenario and its hl children (service discovery, the admin tool) must see the editor's isolated state folders.
    foreach ($property in $cfg.env.PSObject.Properties) { Set-Item -Path ('env:' + $property.Name) -Value ([string]$property.Value) }
    $result = Join-Path $editorDir 'result'
    New-Item -ItemType Directory -Force $result | Out-Null
    Get-ChildItem $result -File -ErrorAction SilentlyContinue | Remove-Item -Force
    $scenario = Join-Path $harness 'gui_scenarios\e2e_pair.py'
    # One GUI scenario at a time on this machine: the scenario moves the real mouse (same lock as measure.ps1).
    $lock = [Threading.Mutex]::new($false, 'Global\exosuit-perf-gui')
    try { $acquired = $lock.WaitOne([TimeSpan]::FromMinutes(7)) } catch [Threading.AbandonedMutexException] { $acquired = $true }
    if (-not $acquired) { throw 'the screen lock is not free after 7 minutes' }
    try {
        Say "running step(s): $($names -join ', ')"
        $timer = [Diagnostics.Stopwatch]::StartNew()
        & $python -I $scenario --pid $state.editorPid --out $result --deadline 240 --wait-window 60
        $code = $LASTEXITCODE
        Say ("step(s) finished with exit {0} in {1:N1} s" -f $code, $timer.Elapsed.TotalSeconds)
    } finally { $lock.ReleaseMutex(); $lock.Dispose() }
    Get-ChildItem $result -Filter *.png -ErrorAction SilentlyContinue | ForEach-Object {
        Copy-Item $_.FullName (Join-Path $screens ($(if ($_.Name -like 'phone-*') { $_.Name } else { 'editor-' + $_.Name }))) -Force }
    if ($code -ne 0) { throw "Step(s) failed (exit $code); results in $result, screenshots in $screens" }
}

function Pair {
    if (Test-Path $pairedPath) { Say 'already paired (reset starts over); checking that the editor still lists the phone'; Invoke-Steps @('pair'); return }
    Invoke-Steps @('pair')
    if (-not (Test-Path $pairedPath)) { throw 'pairing finished but wrote no paired.json' }
    # Save the paired phone as the rig's quick-boot snapshot: the next boot is seconds, already paired.
    Say "saving emulator snapshot '$Snapshot'"
    Adb emu avd snapshot save $Snapshot | Out-Null
}

function Show-Status {
    $state = Read-State
    Initialize-Emulator $Avd $Port
    $ready = Join-Path $hostDir 'ready.json'
    $relay = if (Test-Path $ready) { $r = Get-Content $ready -Raw | ConvertFrom-Json; Test-Listening $r.tlsPort } else { $false }
    $phone = ((& $script:Adb devices) -join "`n") -match "$script:Serial\s+device"
    $up = [bool]($state.ready -and (Test-Alive $state.keeper))
    "ready: $up (keeper pid $($state.keeper))`nrelay: $relay`neditor: $(Test-Alive $state.editorPid) (pid $($state.editorPid))`nemulator: $phone`npaired: $(Test-Path $pairedPath)`nrig: $RunDir"
}

# Stops what `up` started (run by the keeper itself on the way out, or by `down` for a rig whose keeper is gone).
function Stop-Rig {
    $state = Read-State
    # The emulator saves its quick-boot snapshot when it is killed this way.
    if (((& $script:Adb devices) -join "`n") -match "$script:Serial\s+device") {
        # Before the snapshot is saved: a stopped rig must not leave the debug app open to test-rig intents (any app on the
        # device could start a pairing screen). The next `up` creates the marker again before it starts or resumes the app.
        try { & $script:Adb -s $script:Serial shell run-as $package rm -f files/automation.on 2>$null | Out-Null } catch {}
        & $script:Adb -s $script:Serial emu kill 2>$null | Out-Null; Start-Sleep -Seconds 5
    }
    if ($state.emulator) { Get-Process -Id $state.emulator -ErrorAction SilentlyContinue | Stop-Process -Force }
    if (Test-Path (Join-Path $hostDir 'host.log')) { & $python $hostScript stop --out $hostDir 2>&1 | Out-Host }
    foreach ($id in $state.editorPid, $state.editorLauncher, $state.host) {
        if (Test-Alive $id) { & taskkill /T /F /PID $id 2>&1 | Out-Null }
    }
    # What the editor run left: exohost, workspace services, the compiler worker of this checkout (never other checkouts).
    $root = ($RepoRoot -replace '\\', '/')
    Get-CimInstance Win32_Process -Filter "Name='hl.exe'" | Where-Object { $_.CommandLine -and ($_.CommandLine -replace '\\', '/').Contains($root) } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Save-State @{ apkHash = $state.apkHash }   # only the APK hash survives: it says the installed APK is current
    Remove-Item $downPath -Force -ErrorAction SilentlyContinue
    Say 'rig stopped (data kept)'
}

# Asks the keeper to stop the rig (a file it polls) and waits for it; with no keeper, cleans up what a dead one left.
function Down {
    $state = Read-State
    if ((Test-Alive $state.keeper) -and $state.keeper -ne $PID) {
        [IO.File]::WriteAllText($downPath, '1')
        $deadline = (Get-Date).AddSeconds(120)
        while ((Test-Alive $state.keeper) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
        if (Test-Alive $state.keeper) { & taskkill /T /F /PID $state.keeper 2>&1 | Out-Null; Say 'the keeper did not stop in 120 s; ended it' }
        else { Say 'down (data kept)' }
        return
    }
    Initialize-Emulator $Avd $Port
    Stop-Rig
}

function Reset {
    Down
    Initialize-Emulator $Avd $Port
    # A saved snapshot would show a phone paired with a relay that no longer knows it: remove it, and clear the app once on the next up.
    Remove-Item -Recurse -Force (Join-Path $env:ANDROID_AVD_HOME "$Avd.avd\snapshots\$Snapshot") -ErrorAction SilentlyContinue
    foreach ($name in 'host', 'editor', 'credentials', 'screens', 'paired.json', 'config.json', 'fake-claude.log') {
        Remove-Item -Recurse -Force (Join-Path $RunDir $name) -ErrorAction SilentlyContinue
    }
    [IO.File]::WriteAllText((Join-Path $RunDir 'clear-phone'), '1')
    Say 'reset: the rig''s data is gone; the next up clears the phone app once and you pair again'
}

function Clear-PhoneOnce {
    # After a reset only: a clean phone, never on a normal resume.
    if (-not (Test-Path (Join-Path $RunDir 'clear-phone'))) { return }
    Assert-Toolchain; Initialize-Emulator $Avd $Port
    $started = Start-Emulator 'swiftshader_indirect' 240 ''
    Adb shell pm clear $package 2>$null | Out-Null
    Stop-Emulator $started
    Remove-Item (Join-Path $RunDir 'clear-phone') -Force
}

switch ($Command) {
    'up' { Clear-PhoneOnce; Up -Keep }
    'pair' { Pair }
    'step' { if (-not $Step) { throw 'Name the step(s): -Step session[,terminal,beta]' }; Invoke-Steps $Step }
    'status' { Show-Status }
    'down' { Down }
    'reset' { Reset }
    'run' {
        try { Reset; Clear-PhoneOnce; Up; Pair; Invoke-Steps @('session', 'terminal', 'beta') } finally { Stop-Rig }
    }
}
