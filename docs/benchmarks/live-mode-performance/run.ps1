param([Parameter(Mandatory)][string]$Name, [string]$Mode = '', [string]$Script = 'script.json', [int]$Seconds = 44, [int]$Deadline = 600,
	[switch]$Patch, [switch]$NoProfile)
$d = Split-Path -Parent $MyInvocation.MyCommand.Path
$o = "$d\runs\$Name"
$a = @()
if ($Mode) { $a += $Mode }
$a += @("--input-script=$d\$Script", "--capture-dir=$o\frames", "--capture-seconds=$Seconds", "--record-path=$o\record.jsonl",
	'C:/Users/corbi/projects/exosuit', 'C:/Users/corbi/projects/exosuit/src/editor/TextBuffer.hx')
if (-not $NoProfile) { $a = @('--profile') + $a }
$extra = @{}
if ($Patch) {
	$extra = @{ EditFile = 'C:\Users\corbi\projects\exosuit\graphical\src\ui\ExosuitApp.hx'; EditFind = '(indentSettings.insertSpaces ? "Spaces: "';
		EditReplacements = @('(indentSettings.insertSpaces ? "Spaces1: "', '(indentSettings.insertSpaces ? "Spaces2: "', '(indentSettings.insertSpaces ? "Spaces3: "');
		FirstEditAfterSeconds = 3 }
}
& "$d\drive.ps1" -Name $Name -DeadlineSeconds $Deadline -RunArgs $a @extra
