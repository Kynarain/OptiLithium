# Walks every Minecraft release that has both an OptiFine build and a Lithium build through
# tools\matrix.ps1, which builds the jar, launches the client with all three mods, reads the log and
# appends a row to tools\matrix-report.md.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\sweep.ps1
#
# The whole loop is written to tools\sweep.log as it goes. Run it out-of-process (see the README) - a
# detached Java client inside a pipeline keeps the pipeline open, which is the same handle problem
# test\launch.ps1 documents.
param(
	[string[]]$Versions = @(
		'1.20', '1.20.1', '1.20.2', '1.20.4', '1.20.6',
		'1.21', '1.21.1', '1.21.3', '1.21.4', '1.21.6', '1.21.7', '1.21.8', '1.21.9', '1.21.10', '1.21.11',
		'26.1.2'
	),
	[string]$SweepLog = "",
	[int]$TimeoutSeconds = 200
)

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $SweepLog) { $SweepLog = Join-Path $here 'sweep.log' }

function Log([string]$text) {
	$line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $text
	Write-Host $line
	Add-Content -Path $SweepLog -Value $line -Encoding UTF8
}

Set-Content -Path $SweepLog -Value "# OptiLithium sweep, $(Get-Date)" -Encoding UTF8

foreach ($v in $Versions) {
	Log "===== $v ====="
	$out = Join-Path $here "one-$v.log"

	# matrix.ps1 is run through powershell.exe with its output redirected to a file: a pipeline here would be
	# inherited by the detached client and keep this loop's handle open.
	& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'matrix.ps1') -Version $v -TimeoutSeconds $TimeoutSeconds *> $out

	if (Test-Path $out) {
		foreach ($line in (Get-Content $out)) {
			if ($line -match '^\s*== |^\s*prepared|^\s*lithium|^\s*reason|^\s*BUILD|TITLE SCREEN|TIMEOUT|FAILED') {
				Log "  $($line.Trim())"
			}
		}
	}
}

Log "sweep done"
