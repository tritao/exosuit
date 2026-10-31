<#
.SYNOPSIS
Builds the build anatomy page from a folder of runs that measure.ps1 wrote, optionally compared with a baseline.

.DESCRIPTION
Condenses the runs into <Run>\summary.json (summarize.py), then writes the page (build_page.py). With -Baseline
(another run folder, or a folder or file holding a summary.json, such as baselines/2026-10-30) every section shows
before and after, and a "What changed" section leads. -Notes adds the interpretation (see README.md).

-Pdf also writes a printable copy (A3 landscape) and prints it to PDF with headless Microsoft Edge, then checks that
every text of the rendered page is in the PDF and that nothing lies outside a page (pdf_check.py), rendering each
PDF page to <Run>\pdfcheck\pNN.png. Edge runs under the crash-dialog guard with its own temporary profile.

.EXAMPLE
pwsh -NoProfile -File docs/benchmarks/build-report/report.ps1 -Run $env:LOCALAPPDATA\Exosuit\build-reports\exosuit-fresh
pwsh -NoProfile -File docs/benchmarks/build-report/report.ps1 -Run <dir> -Baseline docs/benchmarks/build-report/baselines/2026-10-30 -Pdf
#>
param(
	[Parameter(Mandatory)][string]$Run,
	[string]$Baseline = '',
	[string]$Notes = '',
	[string]$Out = '',
	[switch]$Pdf,
	[string]$PdfOut = '',
	[string]$Edge = "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$python = (Get-Command python -ErrorAction Stop).Source
$Run = (Resolve-Path $Run).Path
if (Get-ChildItem $Run -Filter '*.analysis.json' -ErrorAction SilentlyContinue) {
	& $python -I (Join-Path $here 'summarize.py') $Run
	if ($LASTEXITCODE -ne 0) { throw 'summarize.py failed' }
}
if (-not $Out) { $Out = Join-Path $Run $(if ($Baseline) { 'build-anatomy-after.html' } else { 'build-anatomy.html' }) }
$arguments = @((Join-Path $here 'build_page.py'), $Run, '--out', $Out)
if ($Baseline) { $arguments += @('--baseline', (Resolve-Path $Baseline).Path) }
if ($Notes) { $arguments += @('--notes', (Resolve-Path $Notes).Path) }
$print = [IO.Path]::ChangeExtension($Out, '.print.html')
if ($Pdf) { $arguments += @('--print', $print) }
& $python -I @arguments
if ($LASTEXITCODE -ne 0) { throw 'build_page.py failed' }
if (-not $Pdf) { exit 0 }

if (-not (Test-Path $Edge)) { throw "Microsoft Edge not found at $Edge (pass -Edge)" }
if (-not $PdfOut) { $PdfOut = [IO.Path]::ChangeExtension($Out, '.pdf') }
$edgeProfile = Join-Path ([IO.Path]::GetTempPath()) ('build-report-edge-' + [guid]::NewGuid().ToString('n'))
$guard = Join-Path $here '..\perf-harness\run-guarded.ps1'
$url = 'file:///' + ($print -replace '\\', '/')
$common = "--headless=new --disable-gpu --no-first-run --user-data-dir=`"$edgeProfile`" --virtual-time-budget=20000 --run-all-compositor-stages-before-draw"
try {
	pwsh -NoProfile -File $guard -TimeoutSeconds 120 -Exe $Edge "-ArgLine:$common --no-pdf-header-footer --print-to-pdf=`"$PdfOut`" `"$url`""
	if ($LASTEXITCODE -ne 0 -or -not (Test-Path $PdfOut)) { throw 'printing to PDF failed' }
	$dom = [IO.Path]::ChangeExtension($Out, '.dom.html')
	$log = Join-Path ([IO.Path]::GetTempPath()) ('build-report-dom-' + [guid]::NewGuid().ToString('n') + '.log')
	pwsh -NoProfile -File $guard -TimeoutSeconds 120 -Exe $Edge "-ArgLine:$common --dump-dom `"$url`"" -Log $log | Out-Null
	# The guard's log is the program's stdout: the rendered DOM.
	Copy-Item $log $dom -Force
	Remove-Item $log, "$log.err" -ErrorAction SilentlyContinue
	& $python -I (Join-Path $here 'pdf_check.py') $dom $PdfOut (Join-Path (Split-Path $Out) 'pdfcheck')
	$check = $LASTEXITCODE
} finally {
	Remove-Item -Recurse -Force $edgeProfile -ErrorAction SilentlyContinue
}
Write-Output "page: $Out"
Write-Output "pdf:  $PdfOut (text check exit $check)"
exit $check
