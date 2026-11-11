<#
Acceptance run for Phase 9 on the phone (ADR 0005 section 4): the emulator app pairs ONCE with a machine (suit),
then sees the workspaces the owner grants it, with their groups and sessions, without pairing again.

  pwsh -NoProfile -File android/scripts/machine-acceptance.ps1 [-Avd exosuit-x86_64] [-Port 5554] [-OutDir dir] [-SkipBuild]

Steps (screenshots in -OutDir; LOOK at each one, the logcat waits only prove the state changed):
  1-pairing-code.png    the code on the phone; the script checks it equals the machine's pending code before approving
  2-nothing-granted.png paired and online, "Waiting for the owner to grant workspaces."
  3-alpha-granted.png   the owner granted Alpha: it is listed with its session
  4-both-granted.png    the owner granted Beta later: it appears without pairing again (the pairing code is not asked for twice)
  5-alpha-open.png      Alpha TAPPED open in the Remote list: the Workbench with Alpha's sessions and terminals
  9-claude-terminal.png the fake Claude Code terminal, tapped open, at the phone's width (header shows the grid it was given)
  10-typed.png          soft-keyboard text and Enter: the fake Claude replied; every key is asserted in its log
  11-extra-keys.png     Esc, Tab, Shift+Tab, arrows, sticky Ctrl, Paste: each asserted in the fake Claude's key log
  12-observer.png       a second viewer (the desktop stand-in) took control at 120x30: the phone is read only, with Take control
  13-took-control.png   Take control: the phone has control again and the terminal is refitted to its own grid
  14-new-claude.png     New Agent Session > Claude created a second Claude Code terminal from the phone
  6-beta-open.png       Beta tapped open (Alpha's stream closed): Beta's two sessions
  7-reconnected.png     the app killed and started again: it reconnects from the Keystore and lists both
  8-beta-revoked.png    the owner took Beta back: it leaves the list (and the open Workbench) at once

Taps use fixed pixel positions of the 1080x2400 emulator screen (the AVD in docs/mobile/android.md); the screenshots show
whether they hit. Terminal assertions read the fake TUI's log (tests/workspace-terminals/fake-claude-tui.py), not pixels.

Everything it starts it stops: the desktop test host (scripts/mobile-machine-host.py: local relay, isolated suit, two
workspaces with fake Codex sessions) and the emulator. Prerequisites: the Android toolchain variables
(docs/mobile/android.md), `python scripts/build.py --only agent`, suit and tests/mobile-pairing built (see the host script).
Resume steps (-Step resume-home,resume-back,resume-screen,resume-kill,resume-network,resume-desktop | resume-all): the paired phone comes
back connected and drawn without pairing again. The run pairs ONCE (or, with -Reuse, uses the pairing stored on an already running
rig), opens Alpha's Claude terminal, then for each step does the thing and measures the seconds until the phone shows its machine
online with the open workspace connected (the app's UI snapshot, label-driven) and the terminal drawn; screenshot, element list and a
line in <OutDir>
esume	imes.log per step. Steps share one run, so they are listed in one -Step.
  resume-home     Home, wait 10 s, relaunch with am start
  resume-back     Back at the app's root (moves the task to the background), relaunch
  resume-screen   screen off (keyevent 26), wait 10 s, screen on, unlock swipe
  resume-kill     am force-stop, relaunch: reconnects from the stored credentials
  resume-network  the phone's network goes away (wifi and data off, the adb reverse to the relay removed, adb transport reset)
                  and comes back: a disconnected state is shown while offline, then it reconnects by itself
  resume-desktop  the desktop restarts (suit stops 8 s, starts again on the same home): the phone reconnects by itself
#>
param(
    [string]$Avd = 'exosuit-x86_64',
    [int]$Port = 5554,
    [string]$OutDir = '',
    [switch]$SkipBuild,
    [string]$Gpu = 'host',
    # Stop once the Read only strip has been checked in both directions (pair, open the Claude terminal, take and give control).
    [switch]$ControlOnly,
    # Which side acts first when pairing: the owner approves, or the phone confirms the code. Both must work.
    [ValidateSet('confirm-first', 'approve-first')][string]$PairOrder = 'confirm-first',
    # Resume steps instead of the whole acceptance run (see "Resume steps" below): pair once, open Alpha's Claude terminal, run these.
    [ValidateSet('resume-home', 'resume-back', 'resume-screen', 'resume-kill', 'resume-network', 'resume-desktop', 'resume-all')][string[]]$Step = @(),
    # Use the host and emulator that are already running in -OutDir (host/ready.json) and the stored pairing: no start, install or pairing.
    [switch]$Reuse
)
. (Join-Path $PSScriptRoot 'env.ps1')
. (Join-Path $PSScriptRoot 'emulator-lib.ps1')
. (Join-Path $PSScriptRoot 'phone-ui.ps1')
Assert-Toolchain
Initialize-Emulator $Avd $Port
if (-not $OutDir) { $OutDir = Join-Path $BuildRoot 'machine-acceptance' }
New-Item -ItemType Directory -Force $OutDir | Out-Null
$hostDir = Join-Path $OutDir 'host'
$apk = Join-Path $AndroidRoot 'app/build/outputs/apk/debug/app-debug.apk'
$activity = 'com.exosuit.mobile/com.exosuit.mobile.ExosuitActivity'
$python = (Get-Command python -ErrorAction Stop).Source
$hostScript = Join-Path $RepoRoot 'scripts/mobile-machine-host.py'

function Logcat { (& $script:Adb -s $script:Serial logcat -d) -join "`n" }
function Wait-Log([string]$pattern, [int]$seconds) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        $match = [regex]::Match((Logcat), $pattern)
        if ($match.Success) { return $match.Value }
        Start-Sleep -Seconds 1
    }
    throw "Timed out after $seconds s waiting for '$pattern' in logcat"
}
function Host-Command([string[]]$arguments) { & $python $hostScript @arguments --out $hostDir | Out-Null }
function Start-App([string[]]$extras) {
    & $script:Adb -s $script:Serial shell am start -n $activity @extras | Out-Null
}
function Tap([int]$x, [int]$y, [double]$wait = 1.5) {
    & $script:Adb -s $script:Serial shell input tap $x $y | Out-Null
    Start-Sleep -Seconds $wait
}
# The extra-keys row, the rail and every row are found by label (phone-ui.ps1), never by pixel.
function Tap-Key([string]$name) { Tap-PhoneKey $name }
# The terminal's "Read only / Take control" strip: its button is in the UI tree while the phone is an observer.
function Strip-Visible {
    $snapshot = Get-FreshPhoneSnapshot
    if (-not $snapshot) { return $false }
    @($snapshot.elements | Where-Object { $_.label -cmatch '^Take control$' -and $_.w -gt 0 -and $_.h -gt 0 }).Count -gt 0
}
function Wait-Strip([bool]$want, [int]$seconds) {
    $started = Get-Date
    while (((Get-Date) - $started).TotalSeconds -lt $seconds) {
        if ((Strip-Visible) -eq $want) { Write-Host ("strip {0} after {1:N1} s" -f $(if ($want) { 'shown' } else { 'gone' }), ((Get-Date) - $started).TotalSeconds); return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}
# A screenshot and the UI's element list beside it (look at both).
function Shot([string]$path) { Save-Screen $path; Save-PhoneElements ([IO.Path]::ChangeExtension($path, 'txt')) }
function Fake-Log([string]$path) { if (Test-Path $path) { @(Get-Content $path) } else { @() } }
function Wait-Fake([string]$path, [scriptblock]$test, [string]$what, [int]$seconds = 30) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        if (& $test (Fake-Log $path)) { return }
        Start-Sleep -Milliseconds 500
    }
    throw "Timed out after $seconds s waiting for $what; the fake Claude's log is: $((Fake-Log $path) -join ' | ')"
}

$resumeDir = Join-Path $OutDir 'resume'
# ---- Resume steps ----------------------------------------------------------------------------------------------------------------
# What "back, connected and drawn" means, read from the app's own UI snapshot (devtools.AutomationProbe, label-driven): the machine
# is online, its granted workspaces are listed, the open workspace is connected and its terminal's extra-keys row is on screen.
function Get-ResumeStatus {
    $snapshot = Get-PhoneSnapshot
    if (-not $snapshot -or -not $snapshot.state -or -not $snapshot.state.phone) { return $null }
    $phone = $snapshot.state.phone
    $machines = @($phone.machines)
    [pscustomobject]@{
        Online = (@($machines | Where-Object { $_.online }).Count -ge 1)
        Listed = (@($machines | ForEach-Object { @($_.workspaces) }) -contains 'Alpha')
        Beta = (@($machines | ForEach-Object { @($_.workspaces) }) -contains 'Beta')
        Open = [bool]($phone.open -and $phone.open.connected)
        Drawn = (Find-PhoneElements '^Esc$').Count -gt 0
    }
}
function Resume-Note([string]$text) {
    Write-Host $text
    Add-Content (Join-Path $resumeDir 'times.log') ("{0:HH:mm:ss} {1}" -f (Get-Date), $text)
}
# The snapshot is only rewritten when the picture or state changes: delete it so that a new one proves the app drew after the resume.
function Reset-PhoneSnapshot { & $script:Adb -s $script:Serial shell run-as $script:PhonePackage rm -f files/automation/snapshot.json | Out-Null }
function Wait-ResumeStatus([scriptblock]$test, [int]$seconds) {
    $started = Get-Date
    while (((Get-Date) - $started).TotalSeconds -lt $seconds) {
        $status = Get-ResumeStatus
        if ($status -and (& $test $status)) { return ((Get-Date) - $started).TotalSeconds }
        Start-Sleep -Milliseconds 400
    }
    return $null
}
# -NoTerminal: the step ends with the Workbench showing (Back closed the terminal view on the way to the app's root).
function Finish-Resume([string]$name, [datetime]$from, [int]$limit = 60, [switch]$NoTerminal) {
    $secs = Wait-ResumeStatus { param($s) $s.Online -and $s.Listed -and $s.Open -and ($s.Drawn -or ($NoTerminal -and (Find-PhoneElements '^Workbench$').Count -gt 0)) } $limit
    $elapsed = ((Get-Date) - $from).TotalSeconds
    Start-Sleep -Seconds 1
    Shot (Join-Path $resumeDir "$name.png")
    if ($null -eq $secs) {
        $status = Get-ResumeStatus
        throw "$name : not connected and drawn within $limit s ($($status | ConvertTo-Json -Compress)); see $resumeDir\$name.png"
    }
    if ((Logcat) -match 'exosuit-pairing: code') { throw "$name : the phone asked to pair again" }
    Resume-Note ("{0,-16} PASS connected and drawn {1:N1} s after the resume action" -f $name, $elapsed)
}
# Brings the open Claude terminal back if a step left the phone elsewhere (the resume steps start from it).
function Open-AlphaTerminal {
    if ((Find-PhoneElements '^Esc$').Count -gt 0) { return }
    $open = (Get-PhoneSnapshot).state.phone.open
    if (-not ($open -and $open.connected)) {
        if (-not (Find-PhoneElements '^(Alpha|Beta) .* sessions').Count) { Tap-PhoneElement '^Remote$' -role 1 -after 2 }
        Tap-PhoneElement '^Alpha ' -role 1 -after 1
        $null = Wait-ResumeStatus { param($s) $s.Open } 30
        Start-Sleep -Seconds 3
    } else {
        Tap-PhoneElement '^Workbench$' -role 1 -after 2
    }
    Tap-PhoneElement 'Claude Code' -after 6
}
function Prepare-Resume { Open-AlphaTerminal; & $script:Adb -s $script:Serial logcat -c; Reset-PhoneSnapshot }
function Focus-Package {
    $focus = (& $script:Adb -s $script:Serial shell dumpsys window) -join "`n"
    [regex]::Match($focus, 'mCurrentFocus=Window\{[^ ]+ [^ ]+ ([^}]+)\}').Groups[1].Value
}

function Step-Home {
    Prepare-Resume
    & $script:Adb -s $script:Serial shell input keyevent KEYCODE_HOME | Out-Null
    Start-Sleep -Seconds 10
    if ((Focus-Package) -like "$($script:PhonePackage)*") { throw 'resume-home: Home did not leave the app' }
    Reset-PhoneSnapshot
    $from = Get-Date
    Start-App @()
    Finish-Resume 'resume-home' $from
}
function Step-Back {
    Prepare-Resume
    $presses = 0
    while ($presses -lt 6 -and (Focus-Package) -like "$($script:PhonePackage)*") {
        & $script:Adb -s $script:Serial shell input keyevent KEYCODE_BACK | Out-Null
        $presses++
        Start-Sleep -Seconds 2
    }
    if ((Focus-Package) -like "$($script:PhonePackage)*") { throw 'resume-back: Back never left the app' }
    Resume-Note "resume-back       Back pressed $presses time(s) until the app left the screen"
    Start-Sleep -Seconds 5
    Reset-PhoneSnapshot
    $from = Get-Date
    Start-App @()
    Finish-Resume 'resume-back' $from -NoTerminal
}
function Step-Screen {
    Prepare-Resume
    & $script:Adb -s $script:Serial shell input keyevent KEYCODE_SLEEP | Out-Null
    Start-Sleep -Seconds 10
    $power = (& $script:Adb -s $script:Serial shell dumpsys power) -join ' '
    if ($power -notmatch 'mWakefulness=(Asleep|Dozing)') { throw 'resume-screen: the screen did not turn off' }
    Reset-PhoneSnapshot
    $from = Get-Date
    & $script:Adb -s $script:Serial shell input keyevent KEYCODE_WAKEUP | Out-Null
    & $script:Adb -s $script:Serial shell wm dismiss-keyguard | Out-Null
    Finish-Resume 'resume-screen' $from
}
function Step-Kill {
    Prepare-Resume
    & $script:Adb -s $script:Serial shell am force-stop $script:PhonePackage | Out-Null
    Reset-PhoneSnapshot
    & $script:Adb -s $script:Serial logcat -c
    $from = Get-Date
    Start-App @()
    # The workspace is not open after a cold start: the machine and its workspaces come back, then the terminal is opened again.
    $secs = Wait-ResumeStatus { param($s) $s.Online -and $s.Listed } 60
    if ($null -eq $secs) { Shot (Join-Path $resumeDir 'resume-kill-FAILED.png'); throw 'resume-kill: the machine did not come back online from the stored pairing' }
    Resume-Note ("resume-kill       machine online and workspaces listed {0:N1} s after am start (stored credentials)" -f ((Get-Date) - $from).TotalSeconds)
    Open-AlphaTerminal
    Finish-Resume 'resume-kill' $from
}
function Step-Network {
    Prepare-Resume
    $port = $info.relayPort
    & $script:Adb -s $script:Serial shell svc wifi disable | Out-Null
    & $script:Adb -s $script:Serial shell svc data disable | Out-Null
    & $script:Adb -s $script:Serial reverse --remove "tcp:$port" | Out-Null
    # An established adb reverse connection outlives the rule: resetting the transport drops it, as a lost network would.
    & $script:Adb -s $script:Serial reconnect | Out-Null
    $down = Get-Date
    $secs = Wait-ResumeStatus { param($s) -not $s.Online } 90
    Start-Sleep -Seconds 2
    Shot (Join-Path $resumeDir 'resume-network-offline.png')
    if ($null -eq $secs) { throw 'resume-network: the phone never showed the machine offline while the network was gone' }
    Resume-Note ("resume-network    offline state shown {0:N1} s after the network went away" -f ((Get-Date) - $down).TotalSeconds)
    Start-Sleep -Seconds 8
    $deadline = (Get-Date).AddSeconds(30)
    do { Start-Sleep -Seconds 1; $ok = ((& $script:Adb -s $script:Serial get-state 2>$null) -join '') -eq 'device' } until ($ok -or (Get-Date) -gt $deadline)
    & $script:Adb -s $script:Serial reverse "tcp:$port" "tcp:$port" | Out-Null
    & $script:Adb -s $script:Serial shell svc wifi enable | Out-Null
    & $script:Adb -s $script:Serial shell svc data enable | Out-Null
    $from = Get-Date
    Finish-Resume 'resume-network' $from 120
}
function Step-Desktop {
    Prepare-Resume
    $log = Join-Path $hostDir 'host.log'
    $mark = @(Get-Content $log).Count
    $from = Get-Date
    Host-Command @('restart-suit', '--down-seconds', '8')
    $secs = Wait-ResumeStatus { param($s) -not $s.Online } 60
    Shot (Join-Path $resumeDir 'resume-desktop-offline.png')
    if ($null -eq $secs) { Resume-Note 'resume-desktop    NOTE the phone never showed the machine offline' }
    else { Resume-Note ("resume-desktop    offline state shown {0:N1} s after the restart began" -f ((Get-Date) - $from).TotalSeconds) }
    $deadline = (Get-Date).AddSeconds(90)
    while (-not (@(Get-Content $log | Select-Object -Skip $mark) -match 'suit-restarted') -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
    $from = Get-Date
    Resume-Note 'resume-desktop    suit is back, waiting for the phone'
    Finish-Resume 'resume-desktop' $from 120
    # "Online" in the phone's state can be a dead channel the phone has not noticed yet: prove the live link by a round trip through
    # the NEW suit. The owner takes Beta back; the phone's directory must lose it (then it is granted again).
    $probe = Get-Date
    Host-Command @('revoke-grant', 'Beta')
    $secs = Wait-ResumeStatus { param($s) $s.Online -and -not $s.Beta } 150
    Shot (Join-Path $resumeDir 'resume-desktop-probe.png')
    Host-Command @('grant', 'Beta:read')
    if ($null -eq $secs) { throw 'resume-desktop: the phone never saw the new suit''s directory change (dead channel after the desktop restarted)' }
    Resume-Note ("resume-desktop    live again {0:N1} s after the restart finished (owner's change reached the phone through the new suit)" -f ((Get-Date) - $from).TotalSeconds)
}
function Invoke-ResumeSteps($info) {
    New-Item -ItemType Directory -Force $resumeDir | Out-Null
    $order = @('resume-home', 'resume-back', 'resume-screen', 'resume-kill', 'resume-network', 'resume-desktop')
    $wanted = if ($Step -contains 'resume-all') { $order } else { $order | Where-Object { $Step -contains $_ } }
    foreach ($name in $wanted) {
        Write-Host "== $name"
        switch ($name) {
            'resume-home' { Step-Home }
            'resume-back' { Step-Back }
            'resume-screen' { Step-Screen }
            'resume-kill' { Step-Kill }
            'resume-network' { Step-Network }
            'resume-desktop' { Step-Desktop }
        }
    }
}

if (-not $SkipBuild) {
    & (Join-Path $PSScriptRoot 'build.ps1') -Abi x86_64
    if ($LASTEXITCODE -ne 0) { throw 'Android build failed' }
}
if (-not (Test-Path $apk)) { throw "Build the APK first: $apk" }

$hostProcess = $null
$emulator = $null
try {
    if ($Reuse) {
        $info = Get-Content (Join-Path $hostDir 'ready.json') -Raw | ConvertFrom-Json
    } else {
        Remove-Item -Recurse -Force $hostDir -ErrorAction SilentlyContinue
        $hostProcess = Start-Process $python -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $OutDir 'host-start.log') `
            -RedirectStandardError (Join-Path $OutDir 'host-start.err') -ArgumentList @($hostScript, 'start', '--out', $hostDir)
        $ready = Join-Path $hostDir 'ready.json'
        $deadline = (Get-Date).AddSeconds(240)
        while (-not (Test-Path $ready)) {
            if ((Get-Date) -gt $deadline -or $hostProcess.HasExited) { throw "The test host did not become ready; see $OutDir\host-start.log" }
            Start-Sleep -Seconds 2
        }
        $info = Get-Content $ready -Raw | ConvertFrom-Json
        Write-Host "host: relay $($info.relayOrigin), machine $($info.machineId), workspaces Alpha $($info.workspaces.Alpha) Beta $($info.workspaces.Beta)"

    }

    if (-not $Reuse) {
        $emulator = Start-Emulator $Gpu 240
        & $script:Adb -s $script:Serial install -r $apk | Out-Null
        & $script:Adb -s $script:Serial reverse "tcp:$($info.relayPort)" "tcp:$($info.relayPort)" | Out-Null
        & $script:Adb -s $script:Serial shell pm clear com.exosuit.mobile | Out-Null
        Initialize-PhoneSettings
        Enable-PhoneAutomation
        & $script:Adb -s $script:Serial logcat -c

    }

    if (-not $Reuse) {
        # 1. Pair from the invitation; compare the phone's code with the machine's pending one, then confirm and approve.
        Start-App @('--es', 'pairing_url', "'$($info.invitationUrl)'")
        $phoneCode = (Wait-Log 'exosuit-pairing: code [0-9 ]+' 90) -replace '\D', ''
        # The invitation carries the machine key's fingerprint (#mk=); the phone checked it after the handshake.
        if (-not ((Logcat) -match 'exosuit-pairing: machine key matches the invitation')) { throw 'The phone did not find the invitation''s machine key' }
        $deadline = (Get-Date).AddSeconds(60)
        do {
            Start-Sleep -Seconds 1
            $pairing = Get-Content (Join-Path $hostDir 'pairing.json') -Raw | ConvertFrom-Json
        } until ($pairing.pendingCode -or (Get-Date) -gt $deadline)
        $machineCode = ([string]$pairing.pendingCode) -replace '\D', ''
        Write-Host "phone code $phoneCode, machine code $machineCode"
        if ($phoneCode -ne $machineCode -or -not $phoneCode) { throw "The phone and the machine show different pairing codes" }
        Start-Sleep -Seconds 2
        Shot (Join-Path $OutDir '1-pairing-code.png')
        # The machine's approval and the phone's confirmation race a short timeout on the phone; approve first (the host acts on its
        # next 0.5 s poll), then confirm the shown code. The phone confirms by a tap: no intent extra can confirm a code.
        # EXOSUIT_E2E_ORDER_GAP sets the seconds between the two sides (default 3 approve-first, 12 confirm-first). The machine
        # keeps an early approval for 120 s, so a gap of 30 must still pair.
        $gap = if ($env:EXOSUIT_E2E_ORDER_GAP) { [int]$env:EXOSUIT_E2E_ORDER_GAP } elseif ($PairOrder -eq 'approve-first') { 3 } else { 12 }
        if ($PairOrder -eq 'approve-first') {
            Host-Command @('approve')
            Start-Sleep -Seconds $gap
            Tap-PhoneElement 'The code matches' -role 1 -after 0
        } else {
            # The phone confirms first and waits for the owner: the owner approves some seconds later.
            Tap-PhoneElement 'The code matches' -role 1 -after 0
            Start-Sleep -Seconds $gap
            Host-Command @('approve')
        }
        Wait-Log 'exosuit-machine: \S.* online \[\]' 90 | Out-Null
        Start-Sleep -Seconds 2
        Shot (Join-Path $OutDir '2-nothing-granted.png')

        # 2. The owner grants Alpha; the phone lists it with its session. No second pairing.
        Host-Command @('grant', 'Alpha:all')
        Wait-Log 'exosuit-machine: \S.* online \[Alpha:\w+:1\]' 60 | Out-Null
        Start-Sleep -Seconds 2
        Shot (Join-Path $OutDir '3-alpha-granted.png')

        # 3. Later it grants Beta: it appears on the same channel.
        Host-Command @('grant', 'Beta:read')
        Wait-Log 'exosuit-machine: \S.* online \[Alpha:\w+:1,Beta:\w+:2\]' 60 | Out-Null
        Start-Sleep -Seconds 2
        Shot (Join-Path $OutDir '4-both-granted.png')
        $codes = ([regex]::Matches((Logcat), 'exosuit-pairing: code')).Count
        if ($codes -ne 1) { throw "The phone asked for $codes pairing codes; it must pair once" }

    }

    # 4. Open Alpha by TAPPING its row in the Remote list (rail icon, then the row), and look at its Workbench.
    $fake = $info.fakeClaudeLog
    if (-not (Find-PhoneElements '^(Alpha|Beta) .* sessions').Count) { Tap-PhoneElement '^Remote$' -role 1 -after 2 }  # the rail icon toggles the sidebar
    Tap-PhoneElement '^Alpha ' -role 1 -after 1
    Wait-Log "exosuit-open: $($info.workspaces.Alpha) connected" 60 | Out-Null
    Start-Sleep -Seconds 6
    Shot (Join-Path $OutDir '5-alpha-open.png')

    # 4b. The Claude Code terminal Alpha's service already runs (the fake TUI): tap it open, type, use every extra key.
    $before = (Fake-Log $fake | Where-Object { $_ -eq 'START' }).Count
    Tap-PhoneElement 'Claude Code' -after 8
    Shot (Join-Path $OutDir '9-claude-terminal.png')
    Assert-AppOnTop 'in the Claude terminal'
    if ($Step.Count) {
        Invoke-ResumeSteps $info
        Write-Host "OK: resume steps passed; evidence in $OutDir
esume"
        return
    }

    # 4c. Control and size: a second viewer takes control at 120x30. The phone becomes read only; Take control refits it.
    Host-Command @('hold-control', 'Alpha', 'Alpha Claude Code', '--seconds', '70')
    Wait-Fake $fake { param($l) $l -contains 'SIZE 120 30' } 'the other viewer resizing the terminal to 120x30' 30
    # The host log proves the takeover happened (SIZE 120 30); the phone must show the Read only strip within a few seconds.
    if (-not (Wait-Strip $true 8)) {
        Shot (Join-Path $OutDir '12-observer-NOT-SHOWN.png')
        throw 'the phone did not show the Read only strip within 8 s of the other viewer taking control (see 12-observer-NOT-SHOWN.png)'
    }
    Shot (Join-Path $OutDir '12-observer.png')
    Tap-PhoneElement '^Take control$' -after 1
    if (-not (Wait-Strip $false 8)) { throw 'the strip did not go away within 8 s of Take control' }
    Wait-Fake $fake { param($l) $last = @($l | Where-Object { $_ -like 'SIZE *' })[-1]; $last -and $last -ne 'SIZE 120 30' } 'Take control refitting the terminal to the phone' 30
    Shot (Join-Path $OutDir '13-took-control.png')
    # And the other way: the other viewer takes it back; the phone shows the strip again.
    Host-Command @('hold-control', 'Alpha', 'Alpha Claude Code', '--seconds', '40')
    if (-not (Wait-Strip $true 8)) { throw 'the phone did not show the Read only strip the second time' }
    Tap-PhoneElement '^Take control$' -after 1
    if (-not (Wait-Strip $false 8)) { throw 'the strip did not go away after the second Take control' }
    if ($ControlOnly) { Write-Host 'control-only run: the strip follows control in both directions'; return }

    Assert-AppOnTop 'before typing'
    & $script:Adb -s $script:Serial shell input text hello | Out-Null
    Start-Sleep -Seconds 2
    Tap-Key Enter
    Wait-Fake $fake { param($l) ($l -join ' ') -match 'TEXT h TEXT e TEXT l TEXT l TEXT o KEY ENTER' } 'the typed text and Enter'
    Start-Sleep -Seconds 1
    Shot (Join-Path $OutDir '10-typed.png')

    foreach ($pair in @(@('Esc', 'ESC'), @('Tab', 'TAB'), @('ShiftTab', 'SHIFT_TAB'), @('Up', 'UP'), @('Down', 'DOWN'), @('Left', 'LEFT'), @('Right', 'RIGHT'))) {
        $mark = (Fake-Log $fake).Count
        Tap-Key $pair[0]
        $expected = "KEY $($pair[1])"
        Wait-Fake $fake { param($l) $l.Count -gt $mark -and ($l[$mark..($l.Count - 1)] -contains $expected) } "extra key $($pair[0]) -> $expected" 15
    }
    # Sticky Ctrl then a letter from the soft keyboard is the control character.
    $mark = (Fake-Log $fake).Count
    Tap-Key Ctrl
    & $script:Adb -s $script:Serial shell input text c | Out-Null
    Wait-Fake $fake { param($l) $l.Count -gt $mark -and ($l[$mark..($l.Count - 1)] -contains 'KEY CTRL_C') } 'sticky Ctrl then c -> CTRL_C' 15
    # Paste: the test-rig clipboard_text extra (needs files/automation.on) fills the Android clipboard, the Paste key sends it bracketed.
    Start-App @('--es', 'clipboard_text', "'pasted from the phone'")
    Start-Sleep -Seconds 2
    Tap-Key Paste
    Wait-Fake $fake { param($l) $l -contains 'PASTE pasted from the phone' } 'the pasted clipboard text' 15
    Start-Sleep -Seconds 1
    Shot (Join-Path $OutDir '11-extra-keys.png')

    # 4d. Create a Claude Code terminal from the phone: the Workbench menu, New Agent Session, Claude.
    Tap-PhoneElement '^Workbench$' -role 1 -after 2
    Shot (Join-Path $OutDir '14a-workbench.png')
    Tap-PhoneElement 'Workbench menu|More|Actions' -role 1 -after 1
    Shot (Join-Path $OutDir '14b-menu.png')
    Tap-PhoneElement 'New Agent Session' -after 2
    Tap-PhoneElement '^Claude' -after 1
    Wait-Fake $fake { param($l) (@($l | Where-Object { $_ -eq 'START' })).Count -ge ($before + 1) } 'a second Claude Code terminal started from the phone' 40
    Start-Sleep -Seconds 4
    Shot (Join-Path $OutDir '14-new-claude.png')

    # 4e. Beta, tapped open in the Remote list (the keyboard goes away with the terminal view).
    if (-not (Find-PhoneElements '^(Alpha|Beta) .* sessions').Count) { Tap-PhoneElement '^Remote$' -role 1 -after 2 }  # the rail icon toggles the sidebar
    Tap-PhoneElement '^Beta ' -role 1 -after 1
    Wait-Log "exosuit-open: $($info.workspaces.Beta) connected" 60 | Out-Null
    Start-Sleep -Seconds 6
    Shot (Join-Path $OutDir '6-beta-open.png')

    # 5. Kill the app and start it again with no extras: it reconnects from the Keystore-stored pairing.
    & $script:Adb -s $script:Serial shell am force-stop com.exosuit.mobile | Out-Null
    & $script:Adb -s $script:Serial logcat -c
    Start-App @()
    Wait-Log 'exosuit-machine: \S.* online \[Alpha:\w+:1,Beta:\w+:2\]' 90 | Out-Null
    Start-Sleep -Seconds 3
    Shot (Join-Path $OutDir '7-reconnected.png')
    if ((Logcat) -match 'exosuit-pairing: code') { throw 'The restarted app asked to pair again' }

    # 6. The owner takes Beta back.
    Host-Command @('revoke-grant', 'Beta')
    Wait-Log 'exosuit-machine: \S.* online \[Alpha:\w+:1\]' 60 | Out-Null
    Start-Sleep -Seconds 2
    Shot (Join-Path $OutDir '8-beta-revoked.png')
    Write-Host "OK: screenshots in $OutDir; look at each one"
} finally {
    try { Logcat | Set-Content (Join-Path $OutDir 'logcat.txt') } catch {}
    if ($emulator) { Stop-Emulator $emulator }
    if (-not $Reuse) { & $python $hostScript stop --out $hostDir 2>&1 | Out-Host }
    if ($hostProcess -and -not $hostProcess.HasExited) { Stop-Process -Id $hostProcess.Id -Force -ErrorAction SilentlyContinue }
}
