param([Parameter(Mandatory)][string]$Log, [switch]$Bootstrap)
# Runs scripts/build-windows.ps1 -SkipBootstrap --timings in the current directory (an Exosuit checkout) and writes
# each output line to $Log, prefixed with the Unix time in milliseconds at which it arrived. With -Bootstrap it runs
# only the Haxeon toolchain bootstrap instead, in the same Visual Studio environment build-windows.ps1 loads.
# measure.ps1 and bootstrap.ps1 run it under the crash-dialog guard.
#
# The run ends when the build's own process exits, not when its output closes: haxeon's resident compiler worker
# inherits the output pipe and keeps it open until its idle timeout, a minute or more after the build is done.
Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.IO;
using System.Text;

public static class StampedRun {
	public static int Run(string file, string arguments, string log) {
		var writer = new StreamWriter(log, false, new UTF8Encoding(false));
		writer.AutoFlush = true;
		object gate = new object();
		bool closed = false;
		// A process that inherited the pipe (haxeon's resident compiler worker) can deliver a line after the log closed.
		Action<string> write = line => {
			lock (gate) {
				if (closed) return;
				writer.WriteLine(DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() + " " + line);
				Console.WriteLine(line);
			}
		};
		write("#start");
		var info = new ProcessStartInfo(file, arguments) {
			UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true,
			StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8
		};
		var process = new Process { StartInfo = info };
		process.OutputDataReceived += (s, e) => { if (e.Data != null) write(e.Data); };
		process.ErrorDataReceived += (s, e) => { if (e.Data != null) write(e.Data); };
		process.Start();
		process.BeginOutputReadLine();
		process.BeginErrorReadLine();
		while (!process.HasExited) process.WaitForExit(200);
		// Lines already in the pipe arrive shortly after the exit; a process that inherited the pipe may keep it open.
		System.Threading.Thread.Sleep(300);
		int code = process.ExitCode;
		lock (gate) {
			writer.WriteLine(DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() + " #exit " + code);
			writer.Close();
			closed = true;
		}
		return code;
	}
}
'@
if ($Bootstrap) {
	$helper = Join-Path ([IO.Path]::GetTempPath()) ('build-report-bootstrap-' + [guid]::NewGuid().ToString('n') + '.ps1')
	@'
$ErrorActionPreference = 'Stop'
# Enter-VisualStudio2026 from build-windows.ps1, so the bootstrap sees the environment a full build gives it.
$source = Get-Content -Raw scripts/build-windows.ps1
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$null, [ref]$null)
$function = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Enter-VisualStudio2026' }, $true)
. ([scriptblock]::Create($function.Extent.Text))
Enter-VisualStudio2026
Write-Output '== Haxeon toolchain bootstrap'
cmake -P haxeon/cmake/Bootstrap.cmake
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
# The first build would compile these with the pinned Haxe (scripts/haxeon_cli.py); a checkout that has been built
# once has them, so they belong to the bootstrap rather than to the measured build.
Write-Output '== Haxeon CLI and language server'
python -c "import sys; sys.path.insert(0, 'scripts'); from pathlib import Path; import haxeon_cli as h; root = Path('.').resolve(); sys.exit(h.ensure_language_server(root) or h.run_cli(root, ['help']))"
if (-not (Test-Path haxeon/out/haxeon-cli.hl) -or -not (Test-Path haxeon/out/haxeon-lsp.hl)) { Write-Output 'haxeon-cli.hl or haxeon-lsp.hl is missing'; exit 1 }
exit 0
'@ | Set-Content -Encoding utf8 $helper
	try { $code = [StampedRun]::Run('pwsh', "-NoProfile -File `"$helper`"", $Log) } finally { Remove-Item $helper -ErrorAction SilentlyContinue }
} else {
	$code = [StampedRun]::Run('pwsh', '-NoProfile -File scripts/build-windows.ps1 -SkipBootstrap --timings', $Log)
}
exit $code
