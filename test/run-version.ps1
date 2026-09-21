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
	[string[]]$ExtraJvm = @(),
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
