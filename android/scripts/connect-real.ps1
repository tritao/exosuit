<#
The morning command: opens the Exosuit app in a VISIBLE emulator and pairs it with the running exohost (the one behind the owner's
editor), so the owner only compares the code and approves it in the editor's Remote panel.

  pwsh -NoProfile -File android/scripts/connect-real.ps1 [-DryRun] [-Relay https://...] [-NoAutoPair] [-Avd exosuit-s8] [-Port 5584]

What it does, in order (the same control requests the editor's Remote Access panel sends to exohost's pipe):
  1. remote-status                      read only: is remote access on, which relay.
  2. emulator                           starts AVD exosuit-s8 with a window (or reuses it when emulator-<Port> already runs), installs the debug APK,
                                        turns off the emulator's animations. The emulator keeps running when the script ends.
  3. remote-enable <relay>              ONLY when remote access is off (the panel's "Enable remote access"): the default relay of
                                        src/config/RelayUrl.hx, or -Relay. A relay already in use is never changed.
  4. remote-invite 300                  the panel's "Create pairing invitation": one one-time pairing URL, valid 300 s.
  5. phone                              starts pairing from that URL (the test-rig intent extra, then the rig marker is removed again), or with
                                        -NoAutoPair only puts the URL in the app's pairing field (exosuit://pair link; press Pair yourself).
  6. waits                              until the phone shows its code, prints it and the code exohost holds, then waits (-WaitMinutes, 10)
                                        until the device is paired. YOU: tap "The code matches" on the phone, then in the editor's Remote panel
                                        compare the code and press Approve (choose the workspaces to share).
It never stops or restarts exohost, writes nothing into exohost's home, and never approves anything.

  -DryRun         sends only remote-status, prints what it would do, starts nothing.
  -ExohostHome D  talk to an isolated exohost started with EXOSUIT_EXOHOST_HOME=D (tests; the default is the user's own).
  -AutoApprove    with -ExohostHome only: approve the pending device itself, as the owner would in the editor (proves the mechanism).
  -Headless       no emulator window (tests).
  -SkipInstall    keep the app already on the emulator.
  -LocalRelay     use the repo's relay on this PC (relay/worker, started detached; log and pid in android/build/local-relay; port 18787, reached
                  by the emulator through adb reverse). It is the DEFAULT when the public relay rejects native clients (origin_not_allowed).
                  A real exohost refuses a loopback http relay unless it runs with EXOSUIT_RELAY_ALLOW_LOOPBACK_HTTP=1 (the script says so).
  -SwitchRelay    when remote access is already on with another relay: turn it off and on again with the chosen relay. Devices paired
                  through the old relay must pair again. Without this switch the script never changes a relay in use.
  -StopLocalRelay stops the local relay and removes the emulator's adb reverse rules; touches nothing else.
Stop the emulator afterwards with: adb -s emulator-<Port> emu kill
#>
param(
    [string]$Avd = 'exosuit-s8',
    [int]$Port = 5584,
    [string]$Relay = '',
    [string]$ExohostHome = '',
    [string]$Gpu = 'host',
    [int]$WaitMinutes = 10,
    [switch]$DryRun,
    [switch]$NoAutoPair,
    [switch]$AutoApprove,
    [switch]$Headless,
    [switch]$SkipInstall,
    [switch]$LocalRelay,
    [switch]$SwitchRelay,
    [switch]$StopLocalRelay
)
. (Join-Path $PSScriptRoot 'env.ps1')
. (Join-Path $PSScriptRoot 'emulator-lib.ps1')
. (Join-Path $PSScriptRoot 'phone-ui.ps1')
$python = (Get-Command python -ErrorAction Stop).Source
$control = Join-Path $PSScriptRoot 'connect-real.py'
$localRelayScript = Join-Path $PSScriptRoot 'local-relay.py'
if ($StopLocalRelay) {
    # Ends the relay this script started (never exohost: turn remote access off in the editor's Remote panel, or `exohost remote off`).
    & $python -I $localRelayScript stop
    $adbExe = Join-Path $env:ANDROID_HOME 'platform-tools/adb.exe'
    if (Test-Path $adbExe) { & $adbExe -s "emulator-$Port" reverse --remove-all 2>$null | Out-Null }
    exit 0
}
if ($AutoApprove -and -not $ExohostHome) { throw '-AutoApprove only works with -ExohostHome (an isolated exohost): the owner approves a real one in the editor' }

function Invoke-Control([string[]]$arguments) {
    $homeArguments = if ($ExohostHome) { @('--home', $ExohostHome) } else { @() }
    $output = (& $python -I $control @arguments @homeArguments 2>&1 | ForEach-Object { "$_" }) -join "`n"
    try { return $output | ConvertFrom-Json } catch { throw "exohost control '$($arguments -join ' ')' gave: $output" }
}

$pipe = (Invoke-Control @('pipe')).endpoint
Write-Host "exohost control pipe: $pipe"
$status = Invoke-Control @('status')
if (-not $status.ok) { throw "exohost is not usable: $($status.error). Start the editor (it starts exohost) and run this again." }
Write-Host ("remote access: {0}; relay {1}; {2}" -f $(if ($status.enabled) { 'on' } else { 'OFF' }), $status.origin, $(if ($status.connected) { 'connected' } else { 'not connected' }))
if ($DryRun) {
    $relayText = if ($Relay) { $Relay } else { 'the default relay of src/config/RelayUrl.hx' }
    Write-Host 'DRY RUN. A real run would now:'
    Write-Host "  - start (or reuse) the visible emulator $Avd on port $Port and install android/app/build/outputs/apk/debug/app-debug.apk"
    Write-Host ("  - {0}" -f $(if ($status.enabled) { 'leave remote access and its relay as they are' } else { "send remote-enable with origin $relayText" }))
    Write-Host '  - send remote-invite (ttl 300) and start pairing in the app with that one-time URL'
    Write-Host '  - wait for the device to appear in exohost; you tap "The code matches" on the phone and Approve in the editor'
    exit 0
}

Assert-Toolchain
Initialize-Emulator $Avd $Port
$apk = Join-Path $AndroidRoot 'app/build/outputs/apk/debug/app-debug.apk'
if (-not (Test-Path $apk)) { throw "Build the APK first: pwsh -NoProfile -File android/scripts/build.ps1 ($apk)" }
New-Item -ItemType Directory -Force $BuildRoot | Out-Null

function Logcat { (& $script:Adb -s $script:Serial logcat -d) -join "`n" }
function Get-DefaultRelay { (& $python -I $control relay | ConvertFrom-Json).relay }
# A relay deployed before native clients were supported (the original joao-9f7 account's) answers 403 origin_not_allowed to every
# client without an Origin header, which is every phone: pairing then fails with "Could not connect using this pairing link".
function Test-NativeRelay([string]$origin) {
    if (([Uri]$origin).IsLoopback) { return $true }
    $zero = '00000000000000000000000000000000'
    $probe = (& (Join-Path $env:SystemRoot 'System32/curl.exe') -s -m 20 -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' "$origin/v1/machines/$zero/pair/$zero?secret=$zero") -join ''
    return ($probe -notmatch 'origin_not_allowed')
}
function Start-LocalRelay {
    $info = (& $python -I $localRelayScript start) -join ''
    try { $relayInfo = $info | ConvertFrom-Json } catch { throw "local relay: $info" }
    if (-not $relayInfo.running) { throw "local relay did not start: $info" }
    Write-Host "local relay on $($relayInfo.origin) (pid $($relayInfo.pid), log $($relayInfo.log)); stop it with -StopLocalRelay"
    return $relayInfo.origin
}
function Format-EnableError([string]$reason, [string]$origin) {
    if ($reason -eq 'relay_loopback_disabled') {
        return ("remote-enable refused ${origin}: this exohost only accepts a loopback http relay when it was started with EXOSUIT_RELAY_ALLOW_LOOPBACK_HTTP=1. " +
            "Quit Exosuit (exohost quit), set that variable in the shell that starts the editor, start the editor again and run this again.")
    }
    return "remote-enable failed: $reason"
}
function Test-EmulatorRunning { ((& $script:Adb devices 2>$null) -join "`n") -match "emulator-$Port\s+device" }

# 2. The emulator, with a window for the owner.
if (Test-EmulatorRunning) {
    Write-Host "emulator-$Port is already running; using it"
} else {
    Write-Host "starting the emulator $Avd on port $Port$(if (-not $Headless) { ' (window)' })"
    $null = Start-Emulator $Gpu 360 '' -Visible:(-not $Headless)
}
Initialize-PhoneSettings
if (-not $SkipInstall) { Invoke-Adb "install -r `"$apk`"" 240 }

# 3. Which relay, and remote access on, the way the panel does it. A relay in use is never changed without -SwitchRelay.
$localOrigin = $null
$wantLocal = [bool]$LocalRelay
if (-not $status.enabled) {
    $chosen = $null
    if ($Relay) { $chosen = $Relay }
    elseif ($wantLocal) { }
    elseif (Test-NativeRelay (Get-DefaultRelay)) { }
    else { Write-Host "The public relay $(Get-DefaultRelay) rejects native clients (origin_not_allowed); using a local relay instead."; $wantLocal = $true }
    if ($wantLocal -and -not $Relay) { $localOrigin = Start-LocalRelay; $chosen = $localOrigin }
    $arguments = @('enable'); if ($chosen) { $arguments += @('--relay', $chosen) }
    $enabled = Invoke-Control $arguments
    if (-not $enabled.ok) { throw (Format-EnableError $enabled.error $chosen) }
    Write-Host "remote access turned on, relay $($enabled.origin)"
} else {
    $inUse = [Uri]$status.origin
    $usable = $inUse.IsLoopback -or (Test-NativeRelay $status.origin)
    $ourLocal = $inUse.IsLoopback -and $inUse.Port -eq 18787
    if ($usable -and -not $wantLocal) {
        if ($ourLocal) { $null = Start-LocalRelay }
    } elseif ($ourLocal) {
        $null = Start-LocalRelay
    } elseif (-not $SwitchRelay) {
        $why = if ($usable) { '-LocalRelay was asked for' } else { "the relay in use rejects native clients (origin_not_allowed)" }
        throw ("Remote access is already on with $($status.origin), and $why. Not switching it without your say-so. To switch to the local relay run:`n" +
            "  pwsh -NoProfile -File android/scripts/connect-real.ps1 -SwitchRelay`n" +
            "Switching turns remote access off and on again with the local relay (127.0.0.1:18787). Devices paired through $($status.origin) must pair again; " +
            "this PC must keep the local relay running (connect-real.ps1 -StopLocalRelay stops it).")
    } else {
        Write-Host "-SwitchRelay: turning remote access off and on again with the local relay; devices paired through $($status.origin) must pair again"
        $localOrigin = Start-LocalRelay
        $off = Invoke-Control @('disable')
        if (-not $off.ok) { throw "remote-disable failed: $($off.error)" }
        $enabled = Invoke-Control @('enable', '--relay', $localOrigin)
        if (-not $enabled.ok) { throw (Format-EnableError $enabled.error $localOrigin) }
        Write-Host "remote access turned on, relay $($enabled.origin)"
    }
}
$deadline = (Get-Date).AddSeconds(90)
do {
    $status = Invoke-Control @('status')
    if ($status.connected) { break }
    Start-Sleep -Seconds 2
} until ((Get-Date) -gt $deadline)
if (-not $status.connected) { throw "exohost could not reach the relay $($status.origin): $($status.error)" }
Write-Host "relay connected: $($status.origin)"

$relayUri = [Uri]$status.origin
# A loopback relay (the isolated test host) is reached from the emulator through adb reverse; a public one directly.
if ($relayUri.IsLoopback) {
    & $script:Adb -s $script:Serial reverse "tcp:$($relayUri.Port)" "tcp:$($relayUri.Port)" | Out-Null
    Write-Host "adb reverse tcp:$($relayUri.Port) for the loopback relay"
}

# 4. One one-time invitation.
$invite = Invoke-Control @('invite', '--ttl', '300')
if (-not $invite.ok) { throw "remote-invite failed: $($invite.error)" }
$url = if ($invite.invitation.invitationUrl) { $invite.invitation.invitationUrl } else { $invite.invitation.pairingSocketUrl }
$deviceId = [string]$invite.invitation.deviceId
Write-Host "invitation made for device $($deviceId.Substring(0, 8)), valid $($invite.invitation.expiresInSeconds) s"

# 5. Hand it to the phone.
& $script:Adb -s $script:Serial logcat -c
$activity = 'com.exosuit.mobile/com.exosuit.mobile.ExosuitActivity'
& $script:Adb -s $script:Serial shell am force-stop com.exosuit.mobile | Out-Null
if ($NoAutoPair) {
    $encoded = [Uri]::EscapeDataString($url)
    & $script:Adb -s $script:Serial shell am start -a android.intent.action.VIEW -d "'exosuit://pair?u=$encoded'" $activity | Out-Null
    Write-Host 'The pairing field is filled in the app: press Pair on the phone.'
} else {
    Enable-PhoneAutomation
    try {
        & $script:Adb -s $script:Serial shell am start -n $activity --es pairing_url "'$url'" | Out-Null
        $phoneCode = $null
        $deadline = (Get-Date).AddSeconds(120)
        while ((Get-Date) -lt $deadline -and -not $phoneCode) {
            $match = [regex]::Match((Logcat), 'exosuit-pairing: code ([0-9 ]+)')
            if ($match.Success) { $phoneCode = $match.Groups[1].Value.Trim() } else { Start-Sleep -Seconds 1 }
        }
    } finally {
        # While the marker exists any app on the device can start a pairing screen; it was needed for the one launch only.
        Disable-PhoneAutomation
    }
    if (-not $phoneCode) { throw "The phone did not show a pairing code within 120 s; see adb logcat" }
    Write-Host "PHONE CODE: $phoneCode"
}

# 6. Wait for the owner (or, in a test, for -AutoApprove).
$deadline = (Get-Date).AddMinutes($WaitMinutes)
$announced = $false
$paired = $false
while ((Get-Date) -lt $deadline) {
    $devices = Invoke-Control @('devices')
    $pending = @($devices.pending | Where-Object { $_.deviceId -eq $deviceId })
    if ($pending.Count -gt 0 -and -not $announced) {
        $announced = $true
        Write-Host "EXOHOST CODE: $($pending[0].authenticationCode)  (must equal the phone's)"
        Write-Host 'Now: tap "The code matches" on the phone, then in the editor open Remote Access, compare the code and press Approve.'
        if ($Headless -and -not $AutoApprove) {
            # A headless phone has no screen to tap: confirm the code on it here; the owner still approves in the editor.
            Enable-PhoneAutomation
            try { Tap-PhoneElement 'The code matches' -role 1 -after 0 } finally { Disable-PhoneAutomation }
            Write-Host 'Phone confirmed the code. Approve it in the editor now.'
        }
        if ($AutoApprove) {
            # What the owner does by hand, for a test host: approve in the "editor", then confirm the code on the phone.
            $approved = Invoke-Control @('approve', '--device', $deviceId)
            Write-Host "test approval: ok=$($approved.ok) $($approved.error)"
            Start-Sleep -Seconds 3
            Enable-PhoneAutomation
            try { Tap-PhoneElement 'The code matches' -role 1 -after 0 } finally { Disable-PhoneAutomation }
        }
    }
    $device = @($devices.devices | Where-Object { $_.deviceId -eq $deviceId -and -not $_.revoked })
    if ($device.Count -gt 0) { $paired = $true; break }
    Start-Sleep -Seconds 2
}
if (-not $paired) { throw "Not paired within $WaitMinutes minutes. The emulator is still running; run this again for a new invitation." }
Write-Host "PAIRED: device $($deviceId.Substring(0, 8)) is known to exohost. Pick which workspaces it sees in the editor's Remote Access panel."
Write-Host "The emulator keeps running. Stop it with: $script:Adb -s emulator-$Port emu kill"
exit 0
