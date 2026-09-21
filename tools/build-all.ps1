# Builds every release this project supports and keeps each jar, so a sweep can run without rebuilding between
# releases.
#
# Why: `gradlew build -Pmc=<release>` writes to the same build/libs path every time, so building the next
# release OVERWRITES the previous jar. A sweep that alternates build and measure therefore has one jar at a
# time and cannot be re-run without rebuilding; worse, a run that is still holding an old jar and a rebuild for
# a different release can interleave, and the measurement then belongs to a jar nobody intended to test.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\build-all.ps1
param(
	# Comma-separated. Defaults to everything in build.gradle's yarnBuilds table.
	[string]$Versions = '1.20,1.20.1,1.20.2,1.20.4,1.20.6,1.21,1.21.1,1.21.3,1.21.4,1.21.6,1.21.7,1.21.8,1.21.9,1.21.10,1.21.11',
	# Where the per-release jars are copied. Kept OUTSIDE build/libs on purpose: that directory is wiped by the
	# next build.
	[string]$OutDir = 'C:\Users\kynar\IdeaProjects\optilithium\build\all-jars',
	[string]$LogFile = 'C:\Users\kynar\IdeaProjects\optilithium\tools\build-all.log'
)

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here

New-Item -ItemType Directory -Force $OutDir | Out-Null
Remove-Item $LogFile -ErrorAction SilentlyContinue

$built = @()
$failed = @()

foreach ($v in ($Versions -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
	$started = Get-Date
	"### $v building $($started.ToString('HH:mm:ss'))" | Add-Content $LogFile -Encoding UTF8

	# -Pmc=<release> MUST be quoted. PowerShell splits an unquoted 1.21.6 into "1" and ".21.6", and Gradle then
	# reports "No yarn build is listed for Minecraft 1" - which reads as a missing entry in build.gradle rather
	# than as an argument that never arrived.
	$out = & (Join-Path $root 'gradlew.bat') --offline build -x test "-Pmc=$v" --console=plain 2>&1
	$ok = $LASTEXITCODE -eq 0

	$out | Add-Content $LogFile -Encoding UTF8

	if (-not $ok) {
		$failed += $v
		"### $v FAILED after $([int]((Get-Date) - $started).TotalSeconds)s" | Add-Content $LogFile -Encoding UTF8
		continue
	}

	$jar = Join-Path $root "build\libs\OptiLithium-1.0.0+mc$v.jar"
	if (-not (Test-Path $jar)) {
		$failed += "$v (no jar)"
		"### $v built but produced no $jar" | Add-Content $LogFile -Encoding UTF8
		continue
	}

	Copy-Item $jar (Join-Path $OutDir "OptiLithium-1.0.0+mc$v.jar") -Force
	$built += $v
	"### $v built in $([int]((Get-Date) - $started).TotalSeconds)s" | Add-Content $LogFile -Encoding UTF8
}

# 26.1.2 comes from the :v26 module, which is a separate Loom line and takes no -Pmc.
$started = Get-Date
"### 26.1.2 building $($started.ToString('HH:mm:ss'))" | Add-Content $LogFile -Encoding UTF8
$out = & (Join-Path $root 'gradlew.bat') --offline :v26:build -x test --console=plain 2>&1
$out | Add-Content $LogFile -Encoding UTF8
$jar26 = Join-Path $root 'v26\build\libs\OptiLithium-1.0.0+mc26.1.2.jar'

if ($LASTEXITCODE -eq 0 -and (Test-Path $jar26)) {
	Copy-Item $jar26 (Join-Path $OutDir 'OptiLithium-1.0.0+mc26.1.2.jar') -Force
	$built += '26.1.2'
	"### 26.1.2 built in $([int]((Get-Date) - $started).TotalSeconds)s" | Add-Content $LogFile -Encoding UTF8
} else {
	$failed += '26.1.2'
	"### 26.1.2 FAILED" | Add-Content $LogFile -Encoding UTF8
}

$summary = "built $($built.Count): $($built -join ', ')"
if ($failed.Count) { $summary += "  |  FAILED $($failed.Count): $($failed -join ', ')" }
$summary | Add-Content $LogFile -Encoding UTF8
Write-Host $summary

Get-ChildItem $OutDir -Filter '*.jar' | Select-Object Name,Length,LastWriteTime
