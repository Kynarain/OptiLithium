# Launches one release straight into a world through test/launch.ps1, WITHOUT the OptiLithium/OptiFine mods.
#
# This exists because the rig could not tell two very different failures apart. On 26.1.2 the client reaches
# the title screen, "Sound engine started" is logged, the shader pack loads - and then nothing: no integrated
# server, no "Preparing spawn area". Every mod-side check passes, so the question is whether OptiFine (or
# OptiLithium) is what breaks the quick-play path, or whether the run was never going to load that world.
#
# Measure the baseline first: same version, same game directory layout, same --quickPlaySingleplayer, no mods.
#   - baseline loads the world  -> the mods break quick play, and the fault is ours;
#   - baseline does not         -> the rig or the world is at fault, and no amount of fixer work will show up
#                                  as a difference.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\world-launch.ps1 -VersionId 26.1.2-Fabric-0.19.5
param(
	[Parameter(Mandatory = $true)][string]$VersionId,
	# Local directory name under test\world. Defaults to the version id; one per run, so runs never share logs.
	[string]$GameDirName,
	# Two different names, and mixing them up fails in a confusing way: $WorldSourceName is the save on disk
	# (kept separate so the source is never written to), $WorldName is what the copy is called inside the game
	# directory and what --quickPlaySingleplayer is given.
	[string]$WorldSourceName = '新的世界',
	[string]$WorldName = 'RigWorld',
	[int]$Seconds = 200,
	# Which mods to put in: 'none' | 'mine' | 'of' | 'all'
	[string]$Mods = 'none',
	# Install a shader pack as well. This matters more than it looks: OptiFine's shader code only runs when a
	# pack is present (["OptiLithium] Disable Forge light pipeline" and the whole ShadersTex path are gated on
	# Config.isShaders()), so a baseline without one can pass while the real configuration crashes during game
	# initialisation - which is exactly how the 1.21.6 DynamicTexture crash first looked like a baseline pass.
	[switch]$Shader,
	[string]$ShaderPack = 'C:\Users\kynar\IdeaProjects\optifineoforge-test\game\neoforge-21.10.64\shaderpacks\ComplementaryReimagined_r5.9.3.zip',
	[string]$ShaderPackName = 'ComplementaryReimagined_r5.9.3.zip',
	[string]$JavaHome,
	[string]$Scratch = 'C:\Users\kynar\IdeaProjects\scratch'
)

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here
$testDir = Join-Path $root 'test'

if (-not $GameDirName) { $GameDirName = $VersionId }
$gameDir = Join-Path $testDir "world\$GameDirName"

$mcVersion = ($VersionId -split '-')[0]
$is26 = $mcVersion -like '26.*'
$java17 = @('1.20', '1.20.1', '1.20.2', '1.20.3', '1.20.4')
if (-not $JavaHome) {
	$JavaHome = if ($java17 -contains $mcVersion) { 'C:\Program Files\Java\jdk-17' }
		elseif ($is26) { Join-Path $env:USERPROFILE '.gradle\jdks\eclipse_adoptium-25-amd64-windows.2' }
		else { 'C:\Program Files\Java\jdk-21' }
}

# Stop any client holding this directory before deleting it, and verify the delete - a stale log reports the
# previous run's outcome, which is the failure mode documented at length in tools/in-world.ps1.
Get-CimInstance Win32_Process -Filter "Name='java.exe'" |
	Where-Object { $_.CommandLine -and $_.CommandLine -like "*$gameDir*" } |
	ForEach-Object { cmd /c "taskkill /PID $($_.ProcessId) /T /F" 2>&1 | Out-Null }
Start-Sleep 4
Remove-Item $gameDir -Recurse -Force -ErrorAction SilentlyContinue
if (Test-Path $gameDir) {
	Start-Sleep 4
	Remove-Item $gameDir -Recurse -Force -ErrorAction SilentlyContinue
	if (Test-Path $gameDir) { throw "could not clear $gameDir" }
}

New-Item -ItemType Directory -Force "$gameDir\saves" | Out-Null
$worldSource = Join-Path $env:APPDATA ".minecraft\saves\$WorldSourceName"
if (-not (Test-Path -LiteralPath $worldSource)) {
	# Report what IS there. A bare "no source world at <path>" cannot be told apart from an encoding problem
	# in this script's own parameter default, which is the failure this check was written after hitting.
	$available = @(Get-ChildItem (Join-Path $env:APPDATA '.minecraft\saves') -Directory -ErrorAction SilentlyContinue |
		Select-Object -ExpandProperty Name)
	throw "no source world at '$worldSource'. Saves present: $($available -join ', ')"
}
Copy-Item -LiteralPath $worldSource "$gameDir\saves\$WorldName" -Recurse -Force
if (-not (Test-Path "$gameDir\saves\$WorldName\level.dat")) { throw "the world was not copied" }

if ($Shader) {
	New-Item -ItemType Directory -Force "$gameDir\shaderpacks" | Out-Null
	if (-not (Test-Path $ShaderPack)) { throw "no shader pack at $ShaderPack" }
	Copy-Item $ShaderPack "$gameDir\shaderpacks\" -Force
	# BOM-less on purpose, matching tools/in-world.ps1: OptiFine parses this file as plain text and a leading
	# BOM corrupts the first key, which then reads as "no shader pack selected" without any error.
	$cfg = @(
		"shaderPack=$ShaderPackName", 'oldLighting=false', 'shadowTerrain=true', 'shadowEntities=true',
		'shadowBlockEntities=true', 'shadowTranslucent=true', 'shadowSky=false', 'shadowSunMoon=true',
		'shadowClouds=true', 'shadowUnderwater=true', 'shadowVoid=false', 'shadowCulling=true',
		'shaderPackDebug=false')
	[System.IO.File]::WriteAllLines("$gameDir\optionsshaders.txt", $cfg, (New-Object System.Text.UTF8Encoding($false)))
}

$libsDir = if ($is26) { Join-Path $root 'v26\build\libs' } else { Join-Path $root 'build\libs' }
$built = Join-Path $libsDir "OptiLithium-1.0.0+mc$mcVersion.jar"

# The OptiFine jar is named explicitly per release, exactly as tools/in-world.ps1 does it.
#
# A substring match on the release does not work: "1.21.6" is a substring of nothing else, but "1.21.1" is a
# substring of "1.21.10" and "1.21.11", so -First 1 could hand an experiment the wrong OptiFine build without
# any error - a silent wrong-version result is worse than a failure to launch.
$optifineNames = @{
	'1.20' = 'preview_OptiFine_1.20_HD_U_I5_pre5.jar'; '1.20.1' = 'OptiFine_1.20.1_HD_U_I6.jar'
	'1.20.2' = 'preview_OptiFine_1.20.2_HD_U_I7_pre1.jar'; '1.20.4' = 'OptiFine_1.20.4_HD_U_I7.jar'
	'1.20.6' = 'preview_OptiFine_1.20.6_HD_U_J1_pre18.jar'; '1.21' = 'preview_OptiFine_1.21_HD_U_J1_pre9.jar'
	'1.21.1' = 'OptiFine_1.21.1_HD_U_J1.jar'; '1.21.3' = 'OptiFine_1.21.3_HD_U_J2.jar'
	'1.21.4' = 'OptiFine_1.21.4_HD_U_J3.jar'; '1.21.6' = 'preview_OptiFine_1.21.6_HD_U_J6_pre3.jar'
	'1.21.7' = 'preview_OptiFine_1.21.7_HD_U_J6_pre7.jar'; '1.21.8' = 'preview_OptiFine_1.21.8_HD_U_J6_pre16.jar'
	'1.21.9' = 'preview_OptiFine_1.21.9_HD_U_J7_pre2.jar'; '1.21.10' = 'preview_OptiFine_1.21.10_HD_U_J7_pre11.jar'
	'1.21.11' = 'OptiFine_1.21.11_HD_U_J9.jar'; '26.1.2' = 'preview_OptiFine_26.1.2_HD_U_K1_pre2.jar'
}
$optifineJar = if ($optifineNames.ContainsKey($mcVersion)) {
	Get-Item (Join-Path $Scratch "optifine\$($optifineNames[$mcVersion])") -ErrorAction SilentlyContinue
} else { $null }

$modList = @()
switch ($Mods) {
	'none' { }
	'mine' { if (Test-Path $built) { $modList += $built } }
	'of' { if ($optifineJar) { $modList += $optifineJar.FullName } }
	'all' { if (Test-Path $built) { $modList += $built }; if ($optifineJar) { $modList += $optifineJar.FullName } }
	default { throw "unknown -Mods '$Mods'" }
}
# A requested mod that does not exist must stop the run. Continuing produces a "baseline" that silently
# measured a different configuration than the one asked for, which is indistinguishable from a real result.
if ($Mods -in @('mine', 'all') -and -not (Test-Path $built)) { throw "no OptiLithium jar at $built" }
if ($Mods -in @('of', 'all') -and -not $optifineJar) { throw "no OptiFine jar named for $mcVersion in $Scratch\optifine" }

Write-Host "=== $VersionId  mods=$Mods  java=$JavaHome ==="
Write-Host "  game dir: $gameDir"
foreach ($m in $modList) { Write-Host "  mod     : $(Split-Path -Leaf $m)" }

# NOT splatted, and -Mods is always a non-null array. Two separate traps live in these five lines:
#
#   - launch.ps1 declares [string[]]$Mods and it is MANDATORY. An empty @() binds as "no argument supplied" and
#     the child dies with '缺少参数"Mods"的某个参数', so the launch never happens, no log is written, and the
#     caller reports NO LAUNCH after waiting out its whole poll budget - 416 seconds spent proving that a script
#     can fail to pass an empty array;
#   - -Detach is a [switch]. Splatting it as $true through `powershell.exe -File` sends the literal string
#     "True", which PowerShell refuses: "Cannot convert value System.String to type SwitchParameter". So a
#     switch cannot be splatted at all here and has to be written as the bare word it is.
$modsJoined = (@($modList) | ForEach-Object { "'" + $_ + "'" }) -join ','
$cmd = "& { . '" + (Join-Path $testDir 'launch.ps1') + "'" +
	" -VersionId '$VersionId' -GameDir '$gameDir' -Seconds $Seconds -Detach" +
	" -JavaHome '$JavaHome' -QuickPlayWorld '$WorldName' -Mods @($modsJoined) }"
# The exact child command goes into launch.log's first line. Two rounds were spent reading a NO LAUNCH verdict
# before discovering the child had never started because of an argument-binding error, and the command that
# caused it was not recorded anywhere.
Write-Host "  child   : $cmd"
& powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $cmd *> (Join-Path $gameDir 'launch.log')

# Poll for the outcome instead of sleeping the budget out.
$deadline = (Get-Date).AddSeconds($Seconds + 90)
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

$all = ''
foreach ($f in @('rig-stdout.log', 'logs\latest.log', 'rig-stderr.log')) {
	$p = Join-Path $gameDir $f
	if (Test-Path $p) { $all += [string](Get-Content $p -Raw) }
}
$serverThread = if ($all -match '\[Server thread/INFO\]') { 'yes' } else { 'no' }
$soundEngine = if ($all -match 'Sound engine started') { 'yes' } else { 'no' }
$qpError = @([regex]::Matches($all, 'Quick play disabled|no latest singleplayer world found|failed to load singleplayer world summaries')) |
	ForEach-Object { $_.Value } | Select-Object -Unique

"$VersionId mods=$Mods : $verdict  serverThread=$serverThread  soundEngine=$soundEngine  quickPlayLog=$(if ($qpError) { $qpError -join '+' } else { '-' })"

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
