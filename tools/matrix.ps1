# Builds, launches and reads one OptiLithium version end to end, and appends a row to the matrix report.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\matrix.ps1 -Version 1.21.4
#
# The launch is detached and this script then polls the game's own log, because the client is GUI-subsystem
# and an inherited handle keeps a foreground caller alive long after the window closes (that is what turned a
# 150-second run into a 450-second tool call that reported nothing).
param(
	[Parameter(Mandatory = $true)][string]$Version,
	[switch]$SkipBuild,
	[string]$OptiFineJar = "",
	[string]$LithiumJar = "",
	[int]$TimeoutSeconds = 240,
	[string]$ReportPath = "",
	[switch]$KeepGameDir
)

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here
# The launch/analyze scripts live in test\, not next to this file; $here is tools\.
$testDir = Join-Path $root 'test'
$scratch = 'C:\Users\kynar\IdeaProjects\scratch'

if (-not $ReportPath) { $ReportPath = Join-Path $here 'matrix-report.md' }

# Java release the GAME runs on: 1.20 through 1.20.4 are Java 17, everything after is 21.
#
# This is NOT the JVM the build uses. Loom 1.17 itself requires a Java 21 JVM ("Could not resolve
# net.fabricmc:fabric-loom:1.17.21 ... Dependency requires at least JVM runtime version 21. This build uses a
# Java 17 JVM"), and the Java 17 bytecode target is applied by build.gradle's `javaVersions` table through
# the Gradle toolchain, so building a Java 17 release on a Java 21 JVM is correct and was verified.
$java17 = @('1.20', '1.20.1', '1.20.2', '1.20.3', '1.20.4')
# Releases that need Java 25 (26.1 and newer; Java 21 fails before the window appears). The JDK comes from
# Gradle's own JDK store because 25 is not installed machine-wide - it is what the toolchain already uses.
$java25 = @('26.1', '26.1.1', '26.1.2')
$jdk25 = Join-Path $env:USERPROFILE '.gradle\jdks\eclipse_adoptium-25-amd64-windows.2'

$gameJavaHome = if ($java17 -contains $Version) { 'C:\Program Files\Java\jdk-17' }
	elseif ($java25 -contains $Version) { $jdk25 }
	else { 'C:\Program Files\Java\jdk-21' }

$buildJavaHome = 'C:\Program Files\Java\jdk-21'

# OptiFine build and Lithium build per Minecraft version, as downloaded by the earlier fetch steps.
$optifine = @{
	'1.20'    = 'preview_OptiFine_1.20_HD_U_I5_pre5.jar'
	'1.20.1'  = 'OptiFine_1.20.1_HD_U_I6.jar'
	'1.20.2'  = 'preview_OptiFine_1.20.2_HD_U_I7_pre1.jar'
	'1.20.4'  = 'OptiFine_1.20.4_HD_U_I7.jar'
	'1.20.6'  = 'preview_OptiFine_1.20.6_HD_U_J1_pre18.jar'
	'1.21'    = 'preview_OptiFine_1.21_HD_U_J1_pre9.jar'
	'1.21.1'  = 'OptiFine_1.21.1_HD_U_J1.jar'
	'1.21.3'  = 'OptiFine_1.21.3_HD_U_J2.jar'
	'1.21.4'  = 'OptiFine_1.21.4_HD_U_J3.jar'
	'1.21.6'  = 'preview_OptiFine_1.21.6_HD_U_J6_pre3.jar'
	'1.21.7'  = 'preview_OptiFine_1.21.7_HD_U_J6_pre7.jar'
	'1.21.8'  = 'preview_OptiFine_1.21.8_HD_U_J6_pre16.jar'
	'1.21.9'  = 'preview_OptiFine_1.21.9_HD_U_J7_pre2.jar'
	'1.21.10' = 'preview_OptiFine_1.21.10_HD_U_J7_pre11.jar'
	'1.21.11' = 'OptiFine_1.21.11_HD_U_J9.jar'
	'26.1.2'  = 'preview_OptiFine_26.1.2_HD_U_K1_pre2.jar'
}

$lithium = @{
	'1.20'    = '1.20__lithium-fabric-mc1.20-0.11.2.jar'
	'1.20.1'  = '1.20.1__lithium-fabric-mc1.20.1-0.11.4.jar'
	'1.20.2'  = '1.20.2__lithium-fabric-mc1.20.2-0.12.0.jar'
	'1.20.4'  = '1.20.4__lithium-fabric-mc1.20.4-0.12.1.jar'
	'1.20.6'  = '1.20.6__lithium-fabric-mc1.20.6-0.12.5.jar'
	'1.21'    = '1.21__lithium-fabric-0.15.2+mc1.21.1.jar'
	'1.21.1'  = '1.21.1__lithium-fabric-0.15.4+mc1.21.1.jar'
	'1.21.3'  = '1.21.3__lithium-fabric-0.14.6+mc1.21.3.jar'
	'1.21.4'  = '1.21.4__lithium-fabric-0.15.3+mc1.21.4.jar'
	'1.21.6'  = '1.21.6__lithium-fabric-0.17.0+mc1.21.6.jar'
	'1.21.7'  = '1.21.7__lithium-fabric-0.18.0+mc1.21.7.jar'
	'1.21.8'  = '1.21.8__lithium-fabric-0.18.1+mc1.21.8.jar'
	'1.21.9'  = '1.21.9__lithium-fabric-0.19.2+mc1.21.9.jar'
	'1.21.10' = '1.21.10__lithium-fabric-0.20.1+mc1.21.10.jar'
	'1.21.11' = '1.21.11__lithium-fabric-0.21.4+mc1.21.11.jar'
	'26.1.2'  = '26.1.2__lithium-fabric-0.24.7+mc26.1.2.jar'
}

if (-not $OptiFineJar) {
	if (-not $optifine[$Version]) { throw "no OptiFine build is known for $Version (OptiFine publishes none for it)" }
	$OptiFineJar = Join-Path $scratch "optifine\$($optifine[$Version])"
}
if (-not $LithiumJar) {
	if (-not $lithium[$Version]) { throw "no Lithium build is known for $Version" }
	$LithiumJar = Join-Path $scratch "lithium\$($lithium[$Version])"
}
if (-not (Test-Path $OptiFineJar)) { throw "OptiFine jar missing: $OptiFineJar" }
if (-not (Test-Path $LithiumJar)) { throw "Lithium jar missing: $LithiumJar" }

$gameDir = Join-Path $testDir "run\m$Version"
$log = Join-Path $gameDir 'rig-stdout.log'

# The 26.x line is a project of its own (there is no -Pmc there and no mappings either), so the build command
# and the output directory both differ. See docs/LINES.md.
$is26 = $Version -like '26.*'
$buildTask = if ($is26) { ':v26:build' } else { 'build' }
$libsDir = if ($is26) { Join-Path $root 'v26\build\libs' } else { Join-Path $root 'build\libs' }

# 1. build
if (-not $SkipBuild) {
	$env:JAVA_HOME = $buildJavaHome
	Write-Host "== building OptiLithium for $Version"
	$args = if ($is26) { @($buildTask, '--console=plain') } else { @($buildTask, "-Pmc=$Version", '--console=plain') }
	& (Join-Path $root 'gradlew.bat') @args 2>&1 |
		Select-String -Pattern "BUILD SUCCESSFUL|BUILD FAILED|error:|错误" | ForEach-Object { Write-Host "   $($_.Line)" }
}

$built = Join-Path $libsDir "OptiLithium-1.0.0+mc$Version.jar"
if (-not (Test-Path $built)) { throw "no $built" }

# 2. profile
$mpArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $here 'make-profile.ps1'), '-Version', $Version)
# The Fabric installer is built for Java 21+; the 26.x line's own JDK is 25, and using it here is what keeps
# profile creation independent of which game JDK happens to be installed machine-wide.
if ($is26) { $mpArgs += @('-JavaExe', (Join-Path $jdk25 'bin\java.exe')) }
& powershell @mpArgs 2>&1 | ForEach-Object { Write-Host "   $_" }
$profileId = "$Version-Fabric-0.19.5"

# 3. launch
Remove-Item $gameDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "== launching $Version ($profileId, $gameJavaHome)"
# launch.ps1 is dot-sourced into THIS process - deliberately not started as a nested powershell.exe whose child
# is the Java client. Every nested-shell form tried (a pipeline, a redirection) left the outer call holding a
# handle to the detached client, so a run that had already reached the title screen and been killed still made
# the tool call hang until it timed out. Dot-sourcing has no intermediate process at all.
$stack = Join-Path $testDir 'launch.ps1'
& $stack -VersionId $profileId -GameDir $gameDir -Seconds $TimeoutSeconds -Fresh -Detach `
	-JavaHome $gameJavaHome -Mods $built, $OptiFineJar, $LithiumJar

# 4. poll the game's log until it reaches the title screen, crashes, or the timeout runs out
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$verdict = 'TIMEOUT'
while ((Get-Date) -lt $deadline) {
	Start-Sleep -Seconds 5
	$text = if (Test-Path $log) { [string](Get-Content $log -Raw) } else { '' }
	$latest = Join-Path $gameDir 'logs\latest.log'
	if (Test-Path $latest) { $text += [string](Get-Content $latest -Raw) }

	if ($text -match 'Setting user') { $verdict = 'TITLE SCREEN'; break }
	if ($text -match 'Minecraft has crashed|Failed to launch|Incompatible mods found|Mod resolution failed') { $verdict = 'FAILED'; break }
}

# stop the client if it is still up
$pidFile = Join-Path $gameDir 'rig.pid'
if (Test-Path $pidFile) {
	$targetPid = (Get-Content $pidFile -Raw).Trim()
	$tagFile = Join-Path $gameDir 'rig.tag'
	$tag = if (Test-Path $tagFile) { (Get-Content $tagFile -Raw).Trim() } else { $null }
	$owner = Get-CimInstance Win32_Process -Filter "ProcessId = $targetPid" -ErrorAction SilentlyContinue
	if ($owner -and $tag -and $owner.CommandLine -and $owner.CommandLine.Contains($tag)) {
		& taskkill.exe /PID $targetPid /T /F 2>&1 | Out-Null
	}
}

# 5. read the result
$out = ''
$err = ''
$latestText = ''
if (Test-Path $log) { $out = [string](Get-Content $log -Raw) }
$errFile = Join-Path $gameDir 'rig-stderr.log'
if (Test-Path $errFile) { $err = [string](Get-Content $errFile -Raw) }
$latestPath = Join-Path $gameDir 'logs\latest.log'
if (Test-Path $latestPath) { $latestText = [string](Get-Content $latestPath -Raw) }
$all = "$out`n$latestText"

function Count-Of([string]$pattern) { ([regex]::Matches($all, [regex]::Escape($pattern))).Count }

$prepared = 'not reported'
$m = [regex]::Match($all, 'Prepared (\d+) patched classes \((\d+) skipped, (\d+) failed\)')
if ($m.Success) { $prepared = "$($m.Groups[1].Value) prepared, $($m.Groups[2].Value) skipped, $($m.Groups[3].Value) failed" }

$lithiumLoaded = if ($all -match 'Loaded configuration file for Lithium') { 'yes' } else { 'no' }
$fixerLines = ([regex]::Matches($out, '\[OptiLithium\] [^\r\n]*')).Count

$reasons = @()
foreach ($pattern in @('Mixin transformation of (\S+) failed', 'InjectionError: ([^\r\n]{0,120})', 'VerifyError', 'NoClassDefFoundError', 'NoSuchMethodError', 'AbstractMethodError', 'Failed to prepare the patched class (\S+)')) {
	$matches = [regex]::Matches($all, $pattern)
	foreach ($hit in ($matches | Select-Object -First 2)) { $reasons += $hit.Value }
}
$reasonText = if ($reasons.Count -gt 0) { ($reasons | Select-Object -Unique) -join ' | ' } else { '-' }

Write-Host ""
Write-Host "== $Version : $verdict"
Write-Host "   prepared : $prepared"
Write-Host "   lithium  : $lithiumLoaded"
Write-Host "   reason   : $reasonText"
Write-Host "   log      : $log"

$row = "| $Version | $verdict | $prepared | $lithiumLoaded | $reasonText |"
if (-not (Test-Path $ReportPath)) {
	Set-Content -Path $ReportPath -Value @(
		'# OptiLithium version matrix',
		'',
		'One row per Minecraft release, produced by `tools/matrix.ps1` (build, launch with OptiFine + Lithium, read the log).',
		'',
		'| MC | verdict | patched classes | Lithium loaded | failure reason |',
		'|---|---|---|---|---|'
	) -Encoding UTF8
}
Add-Content -Path $ReportPath -Value $row -Encoding UTF8

if (-not $KeepGameDir) { }
return $row
