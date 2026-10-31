param([int]$MaxMinutes = 40, [int]$QuietChecks = 2)
# Waits until no other build is running: no cl/link/lib/ninja/cmake/clang-cl process, no haxeon-cli build,
# no scripts/build.py or test script. Polls every 30 s. Prints what it saw. Exit 0 when quiet, 1 at the ceiling.
$deadline = (Get-Date).AddMinutes($MaxMinutes)
$quiet = 0
while ($true) {
	$busy = @(Get-CimInstance Win32_Process | Where-Object {
		$cmd = [string]$_.CommandLine
		($_.Name -match '^(cl|clang-cl|link|lib|ninja|cmake|ctest)\.exe$') -or
		($_.Name -eq 'hl.exe' -and $cmd -match 'haxeon-cli\.hl"?\s+(build|test)') -or
		($_.Name -eq 'python.exe' -and $cmd -match '(build\.py|test[-\w]*\.py|check-self-hosting)')
	})
	$stamp = Get-Date -Format 'HH:mm:ss'
	if ($busy.Count -eq 0) {
		$quiet++
		Write-Output "$stamp quiet ($quiet/$QuietChecks)"
		if ($quiet -ge $QuietChecks) { exit 0 }
	} else {
		$quiet = 0
		Write-Output "$stamp busy: $(($busy | ForEach-Object { $_.Name + ':' + ([string]$_.CommandLine).Substring(0, [Math]::Min(110, ([string]$_.CommandLine).Length)) }) -join ' || ')"
	}
	if ((Get-Date) -gt $deadline) { exit 1 }
	Start-Sleep -Seconds 30
}
