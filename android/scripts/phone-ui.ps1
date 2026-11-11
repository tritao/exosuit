# Finds and taps things on the phone by what the UI says they are, never by fixed pixels. Dot-source after emulator-lib.ps1.
# The debug app writes its labelled elements and state to files/automation/snapshot.json (devtools.AutomationProbe) when
# files/automation.on exists; positions there are logical pixels, the screen is logical * density.

$script:PhonePackage = 'com.exosuit.mobile'

function Enable-PhoneAutomation {
    & $script:Adb -s $script:Serial shell run-as $script:PhonePackage mkdir -p files | Out-Null
    & $script:Adb -s $script:Serial shell run-as $script:PhonePackage touch files/automation.on | Out-Null
}

# A fresh AVD shows Gboard onboarding sheets (stylus) over the app that swallow `input text`.
function Initialize-PhoneSettings {
    & $script:Adb -s $script:Serial shell settings put secure stylus_handwriting_enabled 0 | Out-Null
    & $script:Adb -s $script:Serial shell settings put global window_animation_scale 0 | Out-Null
    & $script:Adb -s $script:Serial shell settings put global transition_animation_scale 0 | Out-Null
    & $script:Adb -s $script:Serial shell settings put global animator_duration_scale 0 | Out-Null
}

function Get-PhoneSnapshot {
    $text = (& $script:Adb -s $script:Serial shell run-as $script:PhonePackage cat files/automation/snapshot.json 2>$null) -join "`n"
    if (-not $text) { return $null }
    try { return $text | ConvertFrom-Json } catch { return $null }
}

# A snapshot written within the last 2.5 s by the phone's own clock (the probe rewrites it every second even when nothing
# changed), so a picture the app stopped drawing cannot pass for the current one. Null when none arrives within $seconds.
function Get-FreshPhoneSnapshot([int]$seconds = 6) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        $now = [double](((& $script:Adb -s $script:Serial shell date +%s.%N) -join '').Trim())
        $snapshot = Get-PhoneSnapshot
        if ($snapshot -and ($now - [double]$snapshot.at) -lt 2.5) { return $snapshot }
        Start-Sleep -Milliseconds 400
    }
    return $null
}

# Elements whose label matches the regex (case-sensitive) and that are on screen, in screen order (top to bottom).
function Find-PhoneElements([string]$pattern, [string]$role = '') {
    $snapshot = Get-PhoneSnapshot
    if (-not $snapshot) { return @() }
    @($snapshot.elements | Where-Object { $_.label -cmatch $pattern -and (-not $role -or [string]$_.role -eq $role) -and $_.w -gt 0 -and $_.h -gt 0 -and $_.y -lt $snapshot.viewport.height -and $_.x -lt $snapshot.viewport.width } |
        Sort-Object y, x)
}

# Widget roles in the snapshot: 1 button, 4 text, 5 text field.
function Wait-PhoneElement([string]$pattern, [int]$seconds = 30, [switch]$Gone, [string]$role = '') {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        $found = @(Find-PhoneElements $pattern $role)
        if ($Gone) { if ($found.Count -eq 0) { return $true } } elseif ($found.Count -gt 0) { return $found[0] }
        Start-Sleep -Milliseconds 700
    }
    if ($Gone) { return $false }
    $labels = @(Find-PhoneElements '.' | ForEach-Object { "$($_.role):$($_.label)" }) -join ' | '
    throw "Timed out after $seconds s waiting for a phone element labelled /$pattern/ (role '$role'); on screen: $labels"
}

function Get-PhoneScale {
    $size = [regex]::Match(((& $script:Adb -s $script:Serial shell wm size) -join ' '), '(\d+)x(\d+)')
    $snapshot = Get-PhoneSnapshot
    if (-not $size.Success -or -not $snapshot) { throw 'No screen size or UI snapshot from the phone' }
    [double]$size.Groups[1].Value / [double]$snapshot.viewport.width
}

# Taps the centre of the first (topmost) element matching the pattern; waits for it to exist first.
function Tap-PhoneElement([string]$pattern, [int]$wait = 30, [double]$after = 1.5, [int]$index = 0, [string]$role = '') {
    $null = Wait-PhoneElement $pattern $wait -role $role
    Close-SystemAnrDialog
    $found = @(Find-PhoneElements $pattern $role)
    $element = $found[[Math]::Min($index, $found.Count - 1)]
    $scale = Get-PhoneScale
    $x = [int](($element.x + $element.w / 2) * $scale); $y = [int](($element.y + $element.h / 2) * $scale)
    & $script:Adb -s $script:Serial shell input tap $x $y | Out-Null
    Start-Sleep -Seconds $after
}

# A loaded emulator (the first minutes after a cold boot) shows "System UI isn't responding" and similar dialogs over the
# app; a tap then lands on the dialog's dim area and the app never gets it (seen: "The code matches" swallowed, pairing
# never confirmed). The app's own snapshot cannot see such a window, so look at the window focus and close it first.
function Close-SystemAnrDialog {
    foreach ($attempt in 1..3) {
        $focus = (& $script:Adb -s $script:Serial shell dumpsys window) -join "`n"
        $current = [regex]::Match($focus, 'mCurrentFocus=Window\{[^ ]+ [^ ]+ ([^}]+)\}').Groups[1].Value
        if ($current -notmatch 'Not Responding|isn.t responding') { return }
        Write-Host "closing a system dialog over the app: $current"
        if ($attempt -eq 1) { & $script:Adb -s $script:Serial shell am broadcast -a android.intent.action.CLOSE_SYSTEM_DIALOGS | Out-Null }
        else { & $script:Adb -s $script:Serial shell input keyevent KEYCODE_BACK | Out-Null }
        Start-Sleep -Seconds 1
    }
}

# Throws unless the app's window has the focus: another window (a keyboard sheet, a system dialog) would swallow input.
function Assert-AppOnTop([string]$what = 'before typing') {
    $focus = (& $script:Adb -s $script:Serial shell dumpsys window) -join "`n"
    $current = [regex]::Match($focus, 'mCurrentFocus=Window\{[^ ]+ [^ ]+ ([^}]+)\}').Groups[1].Value
    if ($current -and $current -notlike "$($script:PhonePackage)*") { throw "A foreign window has the focus ${what}: $current" }
}

# Writes the visible labelled elements (role:label x,y wxh) next to a screenshot: what to look at when a step fails.
function Save-PhoneElements([string]$path) {
    $snapshot = Get-PhoneSnapshot
    if ($snapshot) { $snapshot.elements | ForEach-Object { "{0}:{1} {2:N0},{3:N0} {4:N0}x{5:N0}" -f $_.role, $_.label, $_.x, $_.y, $_.w, $_.h } | Set-Content $path }
}

# The touch extra-keys row's accessibility labels (TerminalPane.touchKeyButtons).
$script:TouchKeys = @{ Esc = 'Esc'; Tab = 'Tab'; ShiftTab = 'Shift Tab'; Ctrl = 'Ctrl'; Left = [string][char]0x2190; Down = [string][char]0x2193;
    Up = [string][char]0x2191; Right = [string][char]0x2192; Paste = 'Paste'; Enter = [string][char]0x23CE }
function Tap-PhoneKey([string]$name) { Tap-PhoneElement ('^' + [regex]::Escape($script:TouchKeys[$name]) + '$') 15 1.0 }
