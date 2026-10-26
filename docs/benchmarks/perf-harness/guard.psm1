# Runs commands with a hard timeout and stops them when a crash or error dialog appears.
#
# A crashed or misconfigured run often does not exit: it waits on a modal dialog. HashLink's fatal error box and a debug
# CRT assert belong to the process itself, a Windows Error Reporting box ("... has stopped working") to WerFault.exe,
# and a loader error ("The code execution cannot proceed because X.dll was not found") to csrss.exe. Each is a new
# top-level dialog window, so the guard compares the desktop's dialogs against those present at launch.

if (-not ('PerfHarness.Windows' -as [type])) {
	Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace PerfHarness {
	public class TopWindow {
		public IntPtr Handle; public int ProcessId; public string ClassName; public string Title; public string Text;
	}

	public static class Windows {
		delegate bool EnumProc(IntPtr hwnd, IntPtr lparam);
		[DllImport("user32.dll")] static extern bool EnumWindows(EnumProc callback, IntPtr lparam);
		[DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr parent, EnumProc callback, IntPtr lparam);
		[DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hwnd);
		[DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out int pid);
		[DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr hwnd, StringBuilder text, int count);
		[DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int count);
		[DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr SendMessageTimeout(IntPtr hwnd, uint msg, IntPtr wparam, StringBuilder lparam, uint flags, uint timeout, out IntPtr result);
		[DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hwnd, uint msg, IntPtr wparam, IntPtr lparam);

		static string ClassOf(IntPtr hwnd) { var b = new StringBuilder(256); GetClassName(hwnd, b, b.Capacity); return b.ToString(); }
		static string TitleOf(IntPtr hwnd) { var b = new StringBuilder(1024); GetWindowText(hwnd, b, b.Capacity); return b.ToString(); }

		/* WM_GETTEXT with a timeout: a hung owner must not hang the guard. */
		static string TextOf(IntPtr hwnd) {
			var b = new StringBuilder(4096); IntPtr result;
			SendMessageTimeout(hwnd, 0x000D, (IntPtr)b.Capacity, b, 0x0002, 200, out result);
			return b.ToString();
		}

		public static List<TopWindow> Visible() {
			var list = new List<TopWindow>();
			EnumWindows((hwnd, _) => {
				if (!IsWindowVisible(hwnd)) return true;
				int pid; GetWindowThreadProcessId(hwnd, out pid);
				var w = new TopWindow { Handle = hwnd, ProcessId = pid, ClassName = ClassOf(hwnd), Title = TitleOf(hwnd), Text = "" };
				if (w.ClassName == "#32770") {
					var text = new StringBuilder();
					EnumChildWindows(hwnd, (child, __) => {
						var t = TextOf(child);
						if (t.Length > 0) text.Append(t.Replace("\r", " ").Replace("\n", " ")).Append(" | ");
						return true;
					}, IntPtr.Zero);
					w.Text = text.ToString();
				}
				list.Add(w);
				return true;
			}, IntPtr.Zero);
			return list;
		}
	}
}
'@
}

$script:DialogTitle = 'Fatal|Assert|Runtime Error|Runtime Library|stopped working|has stopped|System Error|Unhandled|Debug Error|Exception|Abort|Application Error|Entry Point Not Found|Unable To Locate|hl\.exe|HashLink'
$script:DialogText = 'hl\.exe|\.hl\b|\.hdll|\.dll|haxeon|exosuit|nativekit|hashlink|python|Fatal|Assert|not found|cannot proceed|Uncaught|exception'

function Get-ProcessTree([int]$RootId) {
	$all = Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name
	$ids = [System.Collections.Generic.HashSet[int]]::new()
	[void]$ids.Add($RootId)
	$frontier = @($RootId)
	while ($frontier.Count) {
		$next = @($all | Where-Object { $frontier -contains $_.ParentProcessId -and -not $ids.Contains([int]$_.ProcessId) } | ForEach-Object { [int]$_.ProcessId })
		foreach ($id in $next) { [void]$ids.Add($id) }
		$frontier = $next
	}
	return $ids
}

function Get-DialogSnapshot {
	$set = [System.Collections.Generic.HashSet[long]]::new()
	foreach ($w in [PerfHarness.Windows]::Visible()) { [void]$set.Add($w.Handle.ToInt64()) }
	return $set
}

<#
.SYNOPSIS
The crash or error dialogs that appeared since `Baseline` and belong to the run: owned by a process in `Tree`, or shown
by WerFault.exe or csrss.exe, or naming the run's programs.
#>
function Find-CrashDialogs($Baseline, $Tree) {
	$found = @()
	foreach ($w in [PerfHarness.Windows]::Visible()) {
		if ($Baseline.Contains($w.Handle.ToInt64())) { continue }
		$owner = try { (Get-Process -Id $w.ProcessId -ErrorAction Stop).ProcessName } catch { '' }
		$ownedByRun = $Tree.Contains($w.ProcessId)
		$reporter = $owner -match '^(WerFault|csrss)$'
		$isDialog = $w.ClassName -eq '#32770'
		$looksLikeError = $w.Title -match $script:DialogTitle
		$mentionsRun = ("$($w.Title) $($w.Text)") -match $script:DialogText
		if (($isDialog -and ($ownedByRun -or $reporter -or $mentionsRun)) -or ($looksLikeError -and ($ownedByRun -or $reporter))) {
			$found += [pscustomobject]@{ Handle = $w.Handle; Owner = "$owner ($($w.ProcessId))"; Class = $w.ClassName; Title = $w.Title; Text = $w.Text }
		}
	}
	return $found
}

function Stop-Tree($Tree) {
	foreach ($id in $Tree) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
}

function Close-Dialogs($Dialogs) {
	foreach ($d in $Dialogs) {
		[void][PerfHarness.Windows]::PostMessage($d.Handle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) # WM_CLOSE
		if ($d.Owner -match '^WerFault \((\d+)\)') { Stop-Process -Id ([int]$Matches[1]) -Force -ErrorAction SilentlyContinue }
	}
}

<#
.SYNOPSIS
Runs a program, stopping its whole process tree at `TimeoutSeconds` or as soon as a crash dialog appears.
Returns an object with ExitCode (124 timeout, 125 dialog), Reason, Dialogs and Seconds. Output goes to `LogPath`
(stdout) and `LogPath.err` (stderr) when given.
#>
function Invoke-Guarded {
	param(
		[Parameter(Mandatory)][string]$FilePath,
		[string[]]$ArgumentList = @(),
		[string]$WorkingDirectory = (Get-Location).Path,
		[Parameter(Mandatory)][int]$TimeoutSeconds,
		[string]$LogPath = '',
		[scriptblock]$OnTick = $null
	)
	$baseline = Get-DialogSnapshot
	$start = @{ FilePath = $FilePath; WorkingDirectory = $WorkingDirectory; PassThru = $true; NoNewWindow = $true }
	if ($ArgumentList.Count) { $start.ArgumentList = $ArgumentList }
	if ($LogPath) { $start.RedirectStandardOutput = $LogPath; $start.RedirectStandardError = "$LogPath.err" }
	$process = Start-Process @start
	$started = Get-Date
	$reason = 'exited'; $dialogs = @(); $code = $null
	$tree = [System.Collections.Generic.HashSet[int]]::new(); [void]$tree.Add($process.Id)
	$lastTree = [datetime]::MinValue
	while (-not $process.HasExited) {
		Start-Sleep -Milliseconds 500
		$elapsed = ((Get-Date) - $started).TotalSeconds
		if (((Get-Date) - $lastTree).TotalSeconds -ge 2) {
			# Keep every process ever seen: a crashed child may already be gone while its dialog stays.
			foreach ($id in (Get-ProcessTree $process.Id)) { [void]$tree.Add($id) }
			$lastTree = Get-Date
		}
		$dialogs = @(Find-CrashDialogs $baseline $tree)
		if ($dialogs.Count) { $reason = 'dialog'; $code = 125; break }
		if ($elapsed -gt $TimeoutSeconds) { $reason = "timeout after $TimeoutSeconds s"; $code = 124; break }
		if ($OnTick) {
			$stop = & $OnTick $process $elapsed $tree
			if ($stop) { $reason = "$stop"; break }
		}
	}
	if (-not $process.HasExited) {
		foreach ($id in (Get-ProcessTree $process.Id)) { [void]$tree.Add($id) }
		Stop-Tree $tree
	} else {
		# Children can outlive the parent with a dialog of their own.
		$late = @(Find-CrashDialogs $baseline $tree)
		if ($late.Count) { $dialogs = $late; $reason = 'dialog'; $code = 125; Stop-Tree $tree }
	}
	if ($dialogs.Count) { Close-Dialogs $dialogs }
	if ($null -eq $code) { $process.WaitForExit(5000) | Out-Null; $code = $process.ExitCode }
	[pscustomobject]@{
		ExitCode = $code; Reason = $reason; Dialogs = $dialogs; Seconds = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)
	}
}

function Format-GuardResult($Result) {
	$lines = @("guard: $($Result.Reason), exit $($Result.ExitCode), $($Result.Seconds) s")
	foreach ($d in $Result.Dialogs) {
		$lines += "guard: DIALOG from $($d.Owner) [$($d.Class)] '$($d.Title)': $($d.Text)"
	}
	return $lines -join "`n"
}

Export-ModuleMember -Function Invoke-Guarded, Format-GuardResult, Find-CrashDialogs, Get-DialogSnapshot, Get-ProcessTree, Stop-Tree, Close-Dialogs
