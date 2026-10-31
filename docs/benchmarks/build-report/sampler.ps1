param(
	[Parameter(Mandatory)][string]$Out,
	[int]$IntervalMs = 500,
	[int]$MaxSeconds = 3600,
	[string]$StopFile = '',
	[int]$WatchPid = 0
)
# Samples build-tool processes every IntervalMs into JSONL, plus a full per-process CPU snapshot every 5 s.
# CPU per core comes from a typeperf process started alongside (1 s, CSV).
$ErrorActionPreference = 'Continue'
$names = 'cl.exe','clang-cl.exe','link.exe','lib.exe','ninja.exe','MSBuild.exe','cmake.exe','hl.exe','python.exe','mt.exe','rc.exe','Tracker.exe','node.exe','npm.exe','git.exe','haxe.exe','pwsh.exe','cmd.exe','vctip.exe','VBCSCompiler.exe','cvtres.exe','ctest.exe','mspdbsrv.exe','ccache.exe'
$filter = ($names | ForEach-Object { "Name='$_'" }) -join ' OR '
$cpuCsv = [IO.Path]::ChangeExtension($Out, '.cpu.csv')
if (Test-Path $cpuCsv) { Remove-Item $cpuCsv }
$typeperf = Start-Process -FilePath typeperf -ArgumentList @('"\Processor(*)\% Processor Time"', '-si', '1', '-sc', "$MaxSeconds", '-f', 'CSV', '-o', "`"$cpuCsv`"", '-y') -WindowStyle Hidden -PassThru
$writer = [IO.StreamWriter]::new($Out, $false, [Text.UTF8Encoding]::new($false))
$writer.AutoFlush = $true
$seen = @{}
$start = [DateTimeOffset]::UtcNow
$tick = 0
$writer.WriteLine((@{ kind = 'start'; t = $start.ToUnixTimeMilliseconds(); typeperfPid = $typeperf.Id; cores = [Environment]::ProcessorCount } | ConvertTo-Json -Compress))
try {
	while ($true) {
		$now = [DateTimeOffset]::UtcNow
		if (($now - $start).TotalSeconds -gt $MaxSeconds) { break }
		if ($StopFile -and (Test-Path $StopFile)) { break }
		if ($WatchPid -and -not (Get-Process -Id $WatchPid -ErrorAction SilentlyContinue)) { break }
		$t = $now.ToUnixTimeMilliseconds()
		$rows = @()
		foreach ($p in (Get-CimInstance Win32_Process -Filter $filter -ErrorAction SilentlyContinue)) {
			$id = [int]$p.ProcessId
			$created = if ($p.CreationDate) { ([DateTimeOffset]$p.CreationDate).ToUnixTimeMilliseconds() } else { 0 }
			$key = "$id/$created"
			if (-not $seen.ContainsKey($key)) {
				$seen[$key] = $true
				$writer.WriteLine((@{ kind = 'proc'; t = $t; pid = $id; ppid = [int]$p.ParentProcessId; name = $p.Name; created = $created; cmd = [string]$p.CommandLine } | ConvertTo-Json -Compress))
			}
			$rows += , @($id, $created, [long]($p.KernelModeTime + $p.UserModeTime), [long]$p.WorkingSetSize)
		}
		$writer.WriteLine((@{ kind = 'sample'; t = $t; procs = $rows } | ConvertTo-Json -Compress -Depth 4))
		if ($tick % 10 -eq 0) {
			$all = foreach ($g in (Get-Process -ErrorAction SilentlyContinue)) {
				try { , @($g.Id, $g.ProcessName, [math]::Round($g.TotalProcessorTime.TotalSeconds, 2)) } catch { }
			}
			$writer.WriteLine((@{ kind = 'all'; t = $t; procs = @($all) } | ConvertTo-Json -Compress -Depth 4))
		}
		$tick++
		$elapsed = ([DateTimeOffset]::UtcNow - $now).TotalMilliseconds
		$sleep = [int]($IntervalMs - $elapsed)
		if ($sleep -gt 10) { Start-Sleep -Milliseconds $sleep }
	}
} finally {
	$writer.WriteLine((@{ kind = 'stop'; t = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() } | ConvertTo-Json -Compress))
	$writer.Close()
	Start-Sleep -Seconds 2
	Stop-Process -Id $typeperf.Id -ErrorAction SilentlyContinue
}
