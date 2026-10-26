param(
	[Parameter(Mandatory)][string]$Name,          # run name; output goes to runs\<Name>
	[string[]]$RunArgs = @(),                     # run.py arguments (mode, profile, app args)
	[int]$DeadlineSeconds = 150,                  # hard kill of the whole tree
	[int]$RecorderMaxMB = 2048,                   # kill if hlprof-live grows past this
	[string]$EditFile = "",                       # live edits: file to edit
	[string]$EditFind = "",                       # text to replace
	[string[]]$EditReplacements = @(),            # one edit per entry, applied in order
	[int]$FirstEditAfterSeconds = 0,              # wait this long after first frame before editing
	[int]$AppSeconds = 0,                         # stop only the editor this long after it starts, so the profiler still exports
	[int]$EditAtAppSeconds = 0                    # write the first edit this long after the editor starts (instead of after first frame)
)
$ErrorActionPreference = 'Stop'
$root = 'C:\Users\corbi\projects\exosuit'
$base = Split-Path -Parent $MyInvocation.MyCommand.Path
$out = Join-Path $base "runs\$Name"
if (Test-Path $out) { Remove-Item -Recurse -Force $out }
New-Item -ItemType Directory -Force $out | Out-Null
$portable = Join-Path $out 'state'
New-Item -ItemType Directory -Force $portable | Out-Null
$log = Join-Path $out 'run.log'
$errlog = Join-Path $out 'run.err.log'

$env:PRAGTICAL_PORTABLE = $portable
$argList = @('scripts/run.py') + $RunArgs
"args: $($argList -join ' ')" | Set-Content (Join-Path $out 'args.txt')
$started = Get-Date
$p = Start-Process -FilePath python.exe -ArgumentList $argList -WorkingDirectory $root -RedirectStandardOutput $log -RedirectStandardError $errlog -PassThru -WindowStyle Hidden

function Descendants([int]$id) {
	$all = Get-CimInstance Win32_Process
	$ids = @($id); $frontier = @($id)
	while ($frontier.Count) {
		$next = @($all | Where-Object { $frontier -contains $_.ParentProcessId } | ForEach-Object { [int]$_.ProcessId })
		$ids += $next; $frontier = $next
	}
	return $ids
}
function Note([string]$text) { $line = "[{0,6:N1}s] {1}" -f ((Get-Date) - $started).TotalSeconds, $text; $line | Add-Content (Join-Path $out 'driver.log'); Write-Output $line }

$original = $null
if ($EditFile) { $original = [IO.File]::ReadAllText($EditFile) }
$editIndex = 0; $firstFrameAt = $null; $waitingPatch = $false; $editSentAt = $null
$reason = 'exited'; $lastProgress = 0; $lastLength = -1; $quietSince = 0
# The editor is the hl.exe running a graphical host build; compile servers and workspace agents are other hl.exe processes.
$appPattern = 'graphical[\\/]build[\\/]host[\\/][^\\/"]+\.hl'
$app = $null; $appStartedAt = $null; $appStopped = $false
try {
	while (-not $p.HasExited) {
		Start-Sleep -Milliseconds 500
		$elapsed = ((Get-Date) - $started).TotalSeconds
		if ($elapsed -gt $DeadlineSeconds) { $reason = "deadline $DeadlineSeconds s"; break }
		$tree = Descendants $p.Id
		$procs = Get-Process -Id $tree -ErrorAction SilentlyContinue
		$dialog = $procs | Where-Object { $_.MainWindowTitle -match 'Fatal|Error|Assert|Debug' }
		if ($dialog) {
			$texts = @()
			try {
				Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
				foreach ($d in $dialog) {
					$el = [System.Windows.Automation.AutomationElement]::FromHandle($d.MainWindowHandle)
					$all = $el.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
					foreach ($e in $all) { if ($e.Current.Name) { $texts += $e.Current.Name } }
					$texts += "(process $($d.Id) $($d.Name) $($d.Path))"
				}
			} catch { $texts += "could not read dialog: $_" }
			Note ("dialog text: " + ($texts -join ' | '))
			$reason = "dialog: $($dialog.MainWindowTitle -join ', ')"; break
		}
		if (($AppSeconds -or $EditAtAppSeconds) -and -not $app) {
			$hl = @(Get-CimInstance Win32_Process -Filter "Name='hl.exe'" | Where-Object { $tree -contains [int]$_.ProcessId })
			$app = $hl | Where-Object { $_.CommandLine -match $appPattern -and $_.CommandLine -notmatch 'haxeon[\\/]compiler|--output' } | Select-Object -First 1
			if ($app) {
				$appStartedAt = $elapsed
				Note "editor started: pid $($app.ProcessId)"
				foreach ($h in $hl) { Note "  hl $($h.ProcessId): $($h.CommandLine)" }
			}
		}
		if ($AppSeconds -and $app -and -not $appStopped -and $elapsed -ge $appStartedAt + $AppSeconds) {
			Note "stopping editor after $AppSeconds s; the profiler finalizes and exports"
			Stop-Process -Id $app.ProcessId -Force -ErrorAction SilentlyContinue
			$appStopped = $true
		}
		$rec = $procs | Where-Object Name -eq 'hlprof-live'
		if ($rec -and ($rec | Measure-Object WorkingSet64 -Sum).Sum / 1MB -gt $RecorderMaxMB) { $reason = 'recorder memory cap'; break }
		$text = (Get-Content $log -Raw -ErrorAction SilentlyContinue) + (Get-Content $errlog -Raw -ErrorAction SilentlyContinue)
		if (-not $firstFrameAt -and $text -match 'first frame ready') { $firstFrameAt = $elapsed; Note 'first frame ready' }
		# Watch and live modes keep waiting for edits after the app exits; stop once the trace and report are out.
		if ($text -match 'Perfetto trace:|profile written to') {
			if ($text.Length -ne $lastLength) { $lastLength = $text.Length; $quietSince = $elapsed }
			elseif ($elapsed - $quietSince -ge 10) { $reason = 'trace written and log quiet'; break }
		}
		if ($elapsed - $lastProgress -ge 15) {
			$lastProgress = $elapsed
			$last = (Get-Content $log -Tail 1 -ErrorAction SilentlyContinue)
			$mem = ($procs | Where-Object Name -in 'hl','hlprof-live' | ForEach-Object { "$($_.Name)=$([int]($_.WorkingSet64/1MB))MB" }) -join ' '
			Note ("progress: $mem | " + ("$last".Substring(0, [Math]::Min(120, "$last".Length))))
		}
		$editReady = if ($EditAtAppSeconds) { $app -and $elapsed -ge $appStartedAt + $EditAtAppSeconds } else { $firstFrameAt -and $elapsed -ge $firstFrameAt + $FirstEditAfterSeconds }
		if ($EditFile -and ($firstFrameAt -or $EditAtAppSeconds)) {
			$patches = ([regex]::Matches($text, 'patched live module to revision (\d+)')).Count
			$reloads = ([regex]::Matches($text, 'reloaded live module to revision (\d+)')).Count
			if ($waitingPatch -and ($patches + $reloads) -ge $editIndex) {
				$waitingPatch = $false; Note ("edit {0} applied after {1:N1}s (patches {2}, reload lines {3})" -f $editIndex, ($elapsed - $editSentAt), $patches, $reloads)
			}
			if (-not $waitingPatch -and $editIndex -lt $EditReplacements.Count -and $editReady) {
				$edited = $original.Replace($EditFind, $EditReplacements[$editIndex])
				if ($edited -eq $original) { throw "edit text not found: $EditFind" }
				[IO.File]::WriteAllText($EditFile, $edited)
				$editIndex++; $waitingPatch = $true; $editSentAt = $elapsed
				Note "edit $editIndex written"
			}
		}
	}
} finally {
	if ($EditFile -and $original -ne $null) { [IO.File]::WriteAllText($EditFile, $original); Note 'edit file restored' }
	if (-not $p.HasExited) {
		Note "stopping tree: $reason"
		foreach ($id in (Descendants $p.Id)) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
	} else { Note "python exited ($($p.ExitCode))" }
	# Compile servers outlive the run and hold its log handles; stop them so every run starts alike.
	Get-CimInstance Win32_Process -Filter "Name='hl.exe'" | Where-Object { $_.CommandLine -match 'haxeon[\\/]compiler' } | ForEach-Object { Note "stopping compile server $($_.ProcessId)"; Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
	# The editor's workspace agent (manager and host) outlives the editor; stop the ones this run started.
	Get-CimInstance Win32_Process -Filter "Name='hl.exe'" | Where-Object { $_.CommandLine -match 'agent[\\/]build[\\/]host[\\/]main\.hl' -and $_.CreationDate -ge $started } | ForEach-Object { Note "stopping workspace agent $($_.ProcessId)"; Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
	Start-Sleep -Seconds 1
	Note ("total {0:N1}s" -f ((Get-Date) - $started).TotalSeconds)
}
