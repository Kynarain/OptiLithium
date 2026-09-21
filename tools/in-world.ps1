# Takes one release all the way into a world with a shader pack, and reports what actually happened.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\in-world.ps1 -Version 1.21.11
#
# tools/matrix.ps1 stops at the title screen. That is not the same as the mod working: chunk rebuild, block
# entity ticking, terrain rendering and shader compilation all happen after a world is loaded, and those are
# exactly the paths this mod's fixers touch. Measured difference between the two checks: 1.20.1 reaches the
# title screen with 412 patched classes and 0 failed, then dies with a NoSuchMethodError the first time a
# chunk needs a block entity - a failure the title-screen matrix cannot see at all.
#
# A world from a NEWER release is loaded by an older one only if that release can read it; this script
# therefore uses one source world and copies it per release, and treats "Preparing spawn area" as the proof
# that the world really opened.
param(
	[Parameter(Mandatory = $true)][string]$Version,
	[string]$WorldSource = "$env:APPDATA\.minecraft\saves\新的世界",
	[string]$ShaderPack = "C:\Users\kynar\IdeaProjects\optifineoforge-test\game\neoforge-21.10.64\shaderpacks\ComplementaryReimagined_r5.9.3.zip",
	[string]$ShaderPackName = "ComplementaryReimagined_r5.9.3.zip",
	[string]$Scratch = "C:\Users\kynar\IdeaProjects\scratch",
	[int]$Seconds = 320,
	[switch]$NoShader
)

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here
$testDir = Join-Path $root 'test'

$java17 = @('1.20', '1.20.1', '1.20.2', '1.20.3', '1.20.4')
$java25 = @('26.1', '26.1.1', '26.1.2')
$jdk25 = Join-Path $env:USERPROFILE '.gradle\jdks\eclipse_adoptium-25-amd64-windows.2'
$gameJavaHome = if ($java17 -contains $Version) { 'C:\Program Files\Java\jdk-17' }
	elseif ($java25 -contains $Version) { $jdk25 }
	else { 'C:\Program Files\Java\jdk-21' }

$optifine = @{
	'1.20' = 'preview_OptiFine_1.20_HD_U_I5_pre5.jar'; '1.20.1' = 'OptiFine_1.20.1_HD_U_I6.jar'
	'1.20.2' = 'preview_OptiFine_1.20.2_HD_U_I7_pre1.jar'; '1.20.4' = 'OptiFine_1.20.4_HD_U_I7.jar'
	'1.20.6' = 'preview_OptiFine_1.20.6_HD_U_J1_pre18.jar'; '1.21' = 'preview_OptiFine_1.21_HD_U_J1_pre9.jar'
	'1.21.1' = 'OptiFine_1.21.1_HD_U_J1.jar'; '1.21.3' = 'OptiFine_1.21.3_HD_U_J2.jar'
	'1.21.4' = 'OptiFine_1.21.4_HD_U_J3.jar'; '1.21.6' = 'preview_OptiFine_1.21.6_HD_U_J6_pre3.jar'
	'1.21.7' = 'preview_OptiFine_1.21.7_HD_U_J6_pre7.jar'; '1.21.8' = 'preview_OptiFine_1.21.8_HD_U_J6_pre16.jar'
	'1.21.9' = 'preview_OptiFine_1.21.9_HD_U_J7_pre2.jar'; '1.21.10' = 'preview_OptiFine_1.21.10_HD_U_J7_pre11.jar'
	'1.21.11' = 'OptiFine_1.21.11_HD_U_J9.jar'; '26.1.2' = 'preview_OptiFine_26.1.2_HD_U_K1_pre2.jar'
}
$lithium = @{
	'1.20' = '1.20__lithium-fabric-mc1.20-0.11.2.jar'; '1.20.1' = '1.20.1__lithium-fabric-mc1.20.1-0.11.4.jar'
	'1.20.2' = '1.20.2__lithium-fabric-mc1.20.2-0.12.0.jar'; '1.20.4' = '1.20.4__lithium-fabric-mc1.20.4-0.12.1.jar'
	'1.20.6' = '1.20.6__lithium-fabric-mc1.20.6-0.12.5.jar'; '1.21' = '1.21__lithium-fabric-0.15.2+mc1.21.1.jar'
	'1.21.1' = '1.21.1__lithium-fabric-0.15.4+mc1.21.1.jar'; '1.21.3' = '1.21.3__lithium-fabric-0.14.6+mc1.21.3.jar'
	'1.21.4' = '1.21.4__lithium-fabric-0.15.3+mc1.21.4.jar'; '1.21.6' = '1.21.6__lithium-fabric-0.17.0+mc1.21.6.jar'
	'1.21.7' = '1.21.7__lithium-fabric-0.18.0+mc1.21.7.jar'; '1.21.8' = '1.21.8__lithium-fabric-0.18.1+mc1.21.8.jar'
	'1.21.9' = '1.21.9__lithium-fabric-0.19.2+mc1.21.9.jar'; '1.21.10' = '1.21.10__lithium-fabric-0.20.1+mc1.21.10.jar'
	'1.21.11' = '1.21.11__lithium-fabric-0.21.4+mc1.21.11.jar'; '26.1.2' = '26.1.2__lithium-fabric-0.24.7+mc26.1.2.jar'
}

$is26 = $Version -like '26.*'
$libsDir = if ($is26) { Join-Path $root 'v26\build\libs' } else { Join-Path $root 'build\libs' }
$built = Join-Path $libsDir "OptiLithium-1.0.0+mc$Version.jar"
$OptiFineJar = Join-Path $Scratch "optifine\$($optifine[$Version])"
$LithiumJar = Join-Path $Scratch "lithium\$($lithium[$Version])"

if (-not (Test-Path $built)) { throw "no $built" }
if (-not (Test-Path $OptiFineJar)) { throw "no $OptiFineJar" }
if (-not (Test-Path $LithiumJar)) { throw "no $LithiumJar" }

$gameDir = Join-Path $testDir "world\w$Version"

# Stop any client still holding this directory BEFORE deleting it, and verify that the delete really happened.
#
# This ordering is the reason an earlier round of these results was wrong. `-Fresh` in launch.ps1 deletes the
# game directory itself, but it cannot: a running JVM holds handles inside `.optilithium/`, so Remove-Item
# fails, prints a warning nobody reads, and the launch then reuses the PREVIOUS run's logs. The polling loop
# below then reads "Preparing spawn area" out of a stale log and reports IN WORLD for a run that actually
# crashed at the title screen - a false positive that survived several rounds of measurement here.
Get-CimInstance Win32_Process -Filter "Name='java.exe'" |
	Where-Object { $_.CommandLine -and $_.CommandLine -like "*optilithium\test\world\*" } |
	ForEach-Object { cmd /c "taskkill /PID $($_.ProcessId) /T /F" 2>&1 | Out-Null }
Start-Sleep 4

Remove-Item $gameDir -Recurse -Force -ErrorAction SilentlyContinue

if (Test-Path $gameDir) {
	# One retry, then refuse. A number derived from a stale log is worse than no number.
	Start-Sleep 4
	Remove-Item $gameDir -Recurse -Force -ErrorAction SilentlyContinue
	if (Test-Path $gameDir) { throw "could not clear $gameDir - a client is still holding it, so results would be stale" }
}

New-Item -ItemType Directory -Force "$gameDir\saves", "$gameDir\shaderpacks" | Out-Null

Copy-Item $WorldSource "$gameDir\saves\RigWorld" -Recurse -Force
if (-not (Test-Path "$gameDir\saves\RigWorld\level.dat")) { throw "the world was not copied from $WorldSource" }

if (-not $NoShader) {
	if (-not (Test-Path $ShaderPack)) { throw "no shader pack at $ShaderPack" }
	Copy-Item $ShaderPack "$gameDir\shaderpacks\" -Force
	$enc = New-Object System.Text.UTF8Encoding($false)
	$cfg = @(
		"shaderPack=$ShaderPackName", 'oldLighting=false', 'shadowTerrain=true', 'shadowEntities=true',
		'shadowBlockEntities=true', 'shadowTranslucent=true', 'shadowSky=false', 'shadowSunMoon=true',
		'shadowClouds=true', 'shadowUnderwater=true', 'shadowVoid=false', 'shadowCulling=true',
		'shaderPackDebug=false')
	[System.IO.File]::WriteAllLines("$gameDir\optionsshaders.txt", $cfg, $enc)
}

Get-CimInstance Win32_Process -Filter "Name='java.exe'" |
	Where-Object { $_.CommandLine -and $_.CommandLine -like "*optilithium\test\world\*" } |
	ForEach-Object { cmd /c "taskkill /PID $($_.ProcessId) /T /F" 2>&1 | Out-Null }
Start-Sleep 2

$mods = @($built, $OptiFineJar, $LithiumJar) -join "','"
$cmd = "& { . '$testDir\run-version.ps1' -VersionId '$Version-Fabric-0.19.5' -GameDir '$gameDir'" +
	" -Seconds $Seconds -Detach -JavaHome '$gameJavaHome' -QuickPlayWorld 'RigWorld' -Mods '$mods' }"
& powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $cmd *> (Join-Path $gameDir 'launch.log')

# Poll for the outcome rather than sleeping the whole budget: a crash shows up in a few seconds, a world load
# takes one to three minutes.
$deadline = (Get-Date).AddSeconds($Seconds + 60)
$verdict = 'NO LAUNCH'
while ((Get-Date) -lt $deadline) {
	Start-Sleep -Seconds 5
	$text = ''
	foreach ($f in @((Join-Path $gameDir 'rig-stdout.log'), (Join-Path $gameDir 'logs\latest.log'))) {
		if (Test-Path $f) { $text += [string](Get-Content $f -Raw) }
	}
	if ($text -match 'Preparing spawn area') { $verdict = 'IN WORLD'; break }
	if ($text -match 'Minecraft has crashed|Failed to launch|Incompatible mods') { $verdict = 'FAILED'; break }
}

# Keep going for a while after the world opens. Shader programs are compiled AFTER the world is up (a hand-run
# of 1.21.11 shows "Preparing spawn area" and then "Program loaded" about 25 seconds later), so reading the log
# the moment the world opens reports programs=0 for a run in which shaders work.
if ($verdict -eq 'IN WORLD') { Start-Sleep -Seconds 70 }

$all = ''
# ONLY the files this run wrote. An earlier version of this script also read whatever happened to be in the
# game directory, and after the CapabilityDispatcher fix it still reported that fix's NoSuchMethodError from
# the previous run's log - a false negative that would have hidden a real fix. The timestamp check is what
# makes the counts below trustworthy; nothing here reads a file the launch did not just create.
$runStart = (Get-Date).AddMinutes(-25)
foreach ($f in @((Join-Path $gameDir 'rig-stdout.log'), (Join-Path $gameDir 'logs\latest.log'), (Join-Path $gameDir 'rig-stderr.log'))) {
	if (-not (Test-Path $f)) { continue }
	if ((Get-Item $f).LastWriteTime -lt $runStart) { continue }
	$all += [string](Get-Content $f -Raw)
}

$crashes = @(Get-ChildItem (Join-Path $gameDir 'crash-reports') -ErrorAction SilentlyContinue).Count
$prep = [regex]::Match($all, 'Prepared (\d+) patched classes \((\d+) skipped, (\d+) failed\)')
$prepText = if ($prep.Success) { "$($prep.Groups[1].Value) / $($prep.Groups[3].Value) failed" } else { '-' }
$programs = ([regex]::Matches($all, 'Program loaded:')).Count
$shaderPack = if ($all -match 'Loaded shaderpack') { 'yes' } else { 'no' }
$errors = @()
foreach ($p in @('Mixin transformation of (\S+) failed','NoSuchMethodError: ''([^\r\n]{0,90})','VerifyError','Could not initialize class (\S+)')) {
	foreach ($h in ([regex]::Matches($all, $p) | Select-Object -First 1)) { $errors += $h.Value }
}
# Logged-but-survived errors are counted separately from the fatal ones above. A NoSuchMethodError raised on
# the server thread does not stop the game - it is caught, logged, and the affected piece of work is skipped -
# but it is still a defect, and folding it into the crash bucket would have hidden it. That is exactly how the
# CapabilityDispatcher problem below stayed invisible through a whole round of title-screen verification.
$logged = ([regex]::Matches($all, '\[Server thread/ERROR\]|\[Render thread/ERROR\]')).Count
$errText = if ($errors.Count) { ($errors | Select-Object -Unique) -join ' | ' } else { '-' }
$lith = if ($all -match 'Loaded configuration file for Lithium') { 'yes' } else { 'no' }

"$Version : $verdict  prepared=$prepText  inWorld=$(if ($all -match 'Preparing spawn area') { 'yes' } else { 'no' })  " +
	"shaderpack=$shaderPack  programs=$programs  lithium=$lith  crashes=$crashes  threadErrors=$logged  $errText"

# stop the client if it is still running
$pidFile = Join-Path $gameDir 'rig.pid'
if (Test-Path $pidFile) {
	$targetPid = (Get-Content $pidFile -Raw).Trim()
	$tagFile = Join-Path $gameDir 'rig.tag'
	$tag = if (Test-Path $tagFile) { (Get-Content $tagFile -Raw).Trim() } else { $null }
	$owner = Get-CimInstance Win32_Process -Filter "ProcessId = $targetPid" -ErrorAction SilentlyContinue
	if ($owner -and $tag -and $owner.CommandLine -and $owner.CommandLine.Contains($tag)) {
		cmd /c "taskkill /PID $targetPid /T /F" 2>&1 | Out-Null
	}
}
