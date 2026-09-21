# Runs one version through test\launch.ps1 and keeps the full console output in a log file.
#
# Exists only because 'powershell -File' splits an argument containing a space ("1.21.1-Fabric 0.19.5")
# into several positional arguments, which then fail to bind to -VersionId. Dot-sourcing the script from
# a -Command block passes the value as one quoted string.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -Command "& { . 'test\run-version.ps1' -VersionId '1.21.1-Fabric 0.19.5' }"
param(
	[string]$VersionId = "1.21.1-Fabric 0.19.5",
	[string]$GameDir,
	[int]$Seconds = 150,
	[string[]]$Mods = @(),
	[string]$JavaHome = "C:\Program Files\Java\jdk-21",
	[int]$MemoryMb = 2048,
	# Extra JVM properties. In-band forms do not survive the shell: an array argument is flattened to
	# comma-joined text by the time it reaches a native child, and ';' and '|' are rewritten (to a statement
	# separator and to a space respectively) before the parameter ever binds. Both failure modes are silent -
	# the JVM gets no property and nothing reports an error, so a run looks exactly like one where the switch
	# was ignored. A file has no separator to lose.
	[string]$ExtraJvm = "",
	# One JVM property per line, read verbatim.
	[string]$ExtraJvmFile = "",
	[string[]]$ExtraGameArgs = @(),
	[string]$QuickPlayWorld = "",
	[switch]$Fresh,
	[switch]$KeepRunning,
	[switch]$Detach,
	[string]$LogFile
)

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Mods = @($Mods | ForEach-Object { $_ -split ';' } | Where-Object { $_ })
$ExtraJvm = @($ExtraJvm -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($ExtraJvmFile) {
	if (-not (Test-Path -LiteralPath $ExtraJvmFile)) { throw "no extra JVM args file at $ExtraJvmFile" }
	# Read with ReadAllLines and no BOM: a leading BOM would become part of the first property's name, which
	# the JVM accepts silently as a property nobody reads.
	$ExtraJvm += [System.IO.File]::ReadAllLines($ExtraJvmFile) |
		ForEach-Object { $_.Trim() } | Where-Object { $_ }
}
if (-not $GameDir) { $GameDir = Join-Path $here "run\$VersionId" }
if (-not $LogFile) { $LogFile = Join-Path $GameDir 'console.log' }
New-Item -ItemType Directory -Force $GameDir | Out-Null

$sw = [System.Diagnostics.Stopwatch]::StartNew()
& (Join-Path $here 'launch.ps1') -VersionId $VersionId -GameDir $GameDir -Seconds $Seconds -Mods $Mods `
	-JavaHome $JavaHome -MemoryMb $MemoryMb -ExtraJvm $ExtraJvm -ExtraGameArgs $ExtraGameArgs `
	-QuickPlayWorld $QuickPlayWorld `
	-Fresh:$Fresh -KeepRunning:$KeepRunning -Detach:$Detach 2>&1 | Tee-Object -FilePath $LogFile
$sw.Stop()

Write-Host ""
Write-Host "  wall clock: $([math]::Round($sw.Elapsed.TotalSeconds,1))s"
Write-Host "  console log: $LogFile"
