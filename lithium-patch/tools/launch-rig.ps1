# Launches one release into a world with an ARBITRARY mod set, for testing a patched Lithium next to OptiFabric.
#
# Why a second launcher rather than a flag on the OptiLithium one: that harness runs a fixed mod list (its own jar
# plus OptiFine plus the stock Lithium) and lives in the OptiLithium repository, which is on hold. This one is
# given its mods, so the same world load and the same evidence standard are used to compare
# patched-Lithium + OptiFabric against anything else, without editing the other project.
#
# It deliberately reuses the OptiLithium rig's LAUNCHER (test\launch.ps1 - profile resolution, natives, argfile,
# quick play) and its WORLD, and reproduces the checks that make a result trustworthy: the game directory is
# deleted and the delete is verified, only files written by this run are read, and the shader pack is installed.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File launch-rig.ps1 `
#     -VersionId 1.21-Fabric-0.19.5 -GameDirName 1.21-lithium-patched `
#     -Mods 'I:\mods\lithium-patch\out\lithium-fabric-mc1.21-patched.jar','...\OptiFabric-1.1.0+mc1.21.jar','...\OptiFine_1.21_HD_U_J1_pre9.jar'
param(
	# The version profile under .minecraft\versions, e.g. "1.21-Fabric-0.19.5".
	[Parameter(Mandatory = $true)][string]$VersionId,
	# The Minecraft release, used for the Java choice and the cache path. Defaults to the profile's prefix.
	[string]$McVersion,
	# Directory name under I:\mods\lithium-patch\work; one per run, so runs never share logs.
	[Parameter(Mandatory = $true)][string]$GameDirName,
	# Full paths of every mod jar to install, comma-separated in ONE argument.
	#
	# Declared [string] and split below, not [string[]]: a caller that comes through a shell hands an array over
	# joined into a single element, so "-Mods a,b,c" would arrive as one path literally named "a,b,c" and fail the
	# existence check. The same trap is documented in the OptiLithium rig for -ExtraJvm and -Versions.
	[Parameter(Mandatory = $true)][string]$Mods,
	# Lines for config\lithium.properties, comma-separated in one argument, e.g. 'mixin.minimal_nonvanilla=false'.
	# Lithium reads that file relative to the GAME directory before mixins are applied, so it has to be in place
	# before the client starts.
	[string]$LithiumOption = '',
	# Do not write config\lithium.properties at all. Used to prove that the patched jar works from its OWN baked
	# defaults, i.e. that a user needs no configuration file - which is the difference between "the patch works if
	# you also copy a config" and "the patch works".
	[switch]$NoLithiumConfig,
	[string]$WorldName = 'RigWorld',
	[int]$Seconds = 300,
	[switch]$NoShader,
	[switch]$ShaderDebug,
	[string[]]$ExtraJvm = @(),
	# The OptiLithium rig, which owns the profile launcher, the world source and the shader pack.
	[string]$RigRepo = 'C:\Users\kynar\IdeaProjects\optilithium'
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here
$testDir = Join-Path $RigRepo 'test'

if (-not $McVersion) { $McVersion = ($VersionId -split '-')[0] }

$gameDir = Join-Path $root "work\$GameDirName"
$worldSource = Join-Path $env:APPDATA '.minecraft\saves\新的世界'
$shaderPack = Join-Path $testDir 'shaderpacks\ComplementaryReimagined_r5.9.3.zip'
$shaderPackName = 'ComplementaryReimagined_r5.9.3.zip'

$jdk25 = Join-Path $env:USERPROFILE '.gradle\jdks\eclipse_adoptium-25-amd64-windows.2'
$gameJavaHome = if ($McVersion -in @('1.20','1.20.1','1.20.2','1.20.3','1.20.4')) { 'C:\Program Files\Java\jdk-17' }
	elseif ($McVersion -like '26.*') { $jdk25 }
	else { 'C:\Program Files\Java\jdk-21' }

if (-not (Test-Path $testDir)) { throw "the OptiLithium rig is not at $testDir" }
if (-not (Test-Path $worldSource)) { throw "no source world at $worldSource, so a world load could not be tested" }

# Both list parameters arrive joined, so each is split back into elements here.
$modList = @($Mods -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$lithiumOptions = @($LithiumOption -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })

if (-not $modList.Count) { throw "no mods were given" }

foreach ($m in $modList) {
	if (-not (Test-Path $m)) { throw "mod not found: $m" }
}

# --- a clean game directory, and the delete VERIFIED ---
#
# A running JVM holds handles inside the game directory, so Remove-Item can fail while printing a warning nobody
# reads; the launch then reuses the previous run's logs and the reader reports the previous run's outcome. That
# false positive is the reason this harness exists in the shape it does.
Get-CimInstance Win32_Process -Filter "Name='java.exe'" |
	Where-Object { $_.CommandLine -and $_.CommandLine -like "*$gameDir*" } |
	ForEach-Object { cmd /c "taskkill /PID $($_.ProcessId) /T /F" 2>&1 | Out-Null }
Start-Sleep 3
Remove-Item $gameDir -Recurse -Force -ErrorAction SilentlyContinue
if (Test-Path $gameDir) {
	Start-Sleep 3
	Remove-Item $gameDir -Recurse -Force -ErrorAction SilentlyContinue
	if (Test-Path $gameDir) { throw "could not clear $gameDir - a client is still holding it, so results would be stale" }
}

New-Item -ItemType Directory -Force "$gameDir\saves", "$gameDir\shaderpacks" | Out-Null

if ($lithiumOptions.Count -and -not $NoLithiumConfig) {
	New-Item -ItemType Directory -Force "$gameDir\config" | Out-Null
	[System.IO.File]::WriteAllLines((Join-Path $gameDir 'config\lithium.properties'), [string[]]$lithiumOptions,
		(New-Object System.Text.UTF8Encoding($false)))
}

Copy-Item $worldSource "$gameDir\saves\$WorldName" -Recurse -Force
if (-not (Test-Path "$gameDir\saves\$WorldName\level.dat")) { throw "the world was not copied" }

if (-not $NoShader) {
	if (-not (Test-Path $shaderPack)) { throw "no shader pack at $shaderPack" }
	Copy-Item $shaderPack "$gameDir\shaderpacks\" -Force
	$cfg = @(
		"shaderPack=$shaderPackName", 'oldLighting=false', 'shadowTerrain=true', 'shadowEntities=true',
		'shadowBlockEntities=true', 'shadowTranslucent=true', 'shadowSky=false', 'shadowSunMoon=true',
		'shadowClouds=true', 'shadowUnderwater=true', 'shadowVoid=false', 'shadowCulling=true',
		"shaderPackDebug=$(if ($ShaderDebug) { 'true' } else { 'false' })")
	[System.IO.File]::WriteAllLines("$gameDir\optionsshaders.txt", [string[]]$cfg, (New-Object System.Text.UTF8Encoding($false)))
}

Write-Host "=== $VersionId  ($($modList.Count) mods) ==="
Write-Host "  game dir : $gameDir"
foreach ($m in $modList) { Write-Host "  mod      : $(Split-Path -Leaf $m)" }
if ($lithiumOptions.Count) { Write-Host "  lithium  : $($lithiumOptions -join ' | ')" }

# --- launch through the OptiLithium rig's launcher ---
$modsJoined = (@($modList) | ForEach-Object { "'" + $_ + "'" }) -join ','
$jvmArgList = @(@($ExtraJvm) | ForEach-Object { $_ -split '[, ]+' } | Where-Object { $_ })
$jvmArgs = if ($jvmArgList.Count) { " -ExtraJvm @(" + (($jvmArgList | ForEach-Object { "'$_'" }) -join ',') + ")" } else { "" }
$cmd = "& { . '" + (Join-Path $testDir 'launch.ps1') + "'" +
	" -VersionId '$VersionId' -GameDir '$gameDir' -Seconds $Seconds -Detach" +
	" -JavaHome '$gameJavaHome' -QuickPlayWorld '$WorldName' -Mods @($modsJoined)$jvmArgs }"
& powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $cmd *> (Join-Path $gameDir 'launch.log')

# --- poll for the outcome instead of sleeping the budget out ---
#
# The three verdicts are deliberately distinct. 'NO LAUNCH' means no client wrote anything at all, which points at
# the profile or the launcher rather than at a mod. 'NO WORLD' means the client ran, wrote a log, and simply never
# opened the world - which is what a hang looks like (OptiFabric 1.14.3 on Loader 0.19.5 stops during OptiFine
# remapping and never prints anything else). Lumping those two together as 'NO LAUNCH' was actively misleading
# during this project, because 'NO LAUNCH' reads like 'the launch failed to start'.
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
	if ($text -match 'Loading Minecraft|SpongePowered MIXIN Subsystem|De-Volderfiying') { $verdict = 'NO WORLD' }
}

# Shader programs are compiled AFTER the world opens (about 25 s later on these releases), so a reader that stops
# at "Preparing spawn area" reports programs=0 for a run where shaders work.
if ($verdict -eq 'IN WORLD') { Start-Sleep -Seconds 70 }

# --- evidence, from this run's files only ---
$all = ''
foreach ($f in @('rig-stdout.log', 'logs\latest.log', 'rig-stderr.log')) {
	$p = Join-Path $gameDir $f
	if (Test-Path $p) { $all += [string](Get-Content $p -Raw) }
}

$crashes = @(Get-ChildItem (Join-Path $gameDir 'crash-reports') -ErrorAction SilentlyContinue).Count
$prep = [regex]::Match($all, 'Prepared (\d+) patched classes \((\d+) skipped, (\d+) failed\)')
$prepText = if ($prep.Success) { "$($prep.Groups[1].Value) / $($prep.Groups[3].Value) failed" } else { '-' }
$programs = ([regex]::Matches($all, 'Program loaded:')).Count
$shaderPackLoaded = if ($all -match 'Loaded shaderpack') { 'yes' } else { 'no' }
$lithiumLoaded = if ($all -match 'Loaded configuration file for Lithium') { 'yes' } else { 'no' }

# The loader refuses the whole launch when a `breaks` entry names a mod that is present; that is the one failure
# this project exists to remove, so it is reported on its own line rather than buried in a stack trace.
$conflict = if ($all -match 'Incompatible mods found|NEG_HARD_DEP') { 'YES' } else { 'no' }
$breaksLine = [regex]::Match($all, 'breaks [^\r\n]{0,120}')
if ($breaksLine.Success) { $conflict = "YES: $($breaksLine.Value)" }

# Explicitly disabling a mixin group is a legitimate part of the patch, and it should be visible in the result.
#
# Counted as DISTINCT mixin names, not as matching lines. $all is rig-stdout.log concatenated with latest.log, so
# each disabling is present twice and a line count reports double the truth - a run that disabled 15 mixins
# printed "disabledMixins=30", which reads like 30. Unique names also survive the two logs prefixing lines
# differently. NOTE: this counts only what Lithium LOGS, and Lithium logs only user overrides; switches baked into
# the jar's own defaults are silent, so a 0 here does not mean nothing was switched off (see the README).
$disabledNames = [regex]::Matches($all, "Force-disabl\w+ mixin '([^']+)'") |
	ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
$disabled = @($disabledNames).Count

$rigNoise = @(
	'Failed to verify authentication',
	'Failed to load random sequence',
	'authentication error with message',
	'Failed to fetch user properties',
	'Could not authorize you against Realms server',
	"Couldn't connect to realms",
	'Failed to fetch Realms feature flags'
)
$threadErrorLines = @(($all -split "`r?`n") | Where-Object { $_ -match '\[Server thread/ERROR\]|\[Render thread/ERROR\]' })
$mine = @($threadErrorLines | Where-Object { $line = $_; -not ($rigNoise | Where-Object { $line -like "*$_*" }) })

# The pipeline's own fatal markers are collected separately from the surviving errors above: a mixin failure is
# reported by Mixin, not by the server thread, and it is fatal long before a world loads.
$fatal = @()
foreach ($p in @('Mixin transformation of (\S+) failed','InvalidInjectionException','NoSuchMethodError: ''([^\r\n]{0,90})','VerifyError','Could not initialize class (\S+)','NoClassDefFoundError: ([^\r\n]{0,90})')) {
	foreach ($h in ([regex]::Matches($all, $p) | Select-Object -First 2)) { $fatal += $h.Value }
}

# A verdict of NO WORLD is ambiguous on its own: it covers "the client crashed early", "the client is hung" and
# "the client is still loading and the window ended". The last one produced a wrong conclusion in this project
# (26.1.2, README 6.13), so the state of the client at the moment of the verdict is reported with it:
#
#   clientAlive=yes  the client process still exists  - it did not fail, it had not finished
#   silentFor=<s>    seconds since the client last wrote a log line - a stalled run shows a large number here,
#                    a crashed one stops writing and then exits (clientAlive=no)
$clientAlive = @(Get-CimInstance Win32_Process -Filter "Name='java.exe'" -ErrorAction SilentlyContinue |
	Where-Object { $_.CommandLine -and $_.CommandLine -like "*$gameDir*" }).Count -gt 0
$silentFor = '-'
$lastWrite = $null
foreach ($f in @((Join-Path $gameDir 'logs\latest.log'), (Join-Path $gameDir 'rig-stdout.log'))) {
	if (Test-Path $f) {
		$w = (Get-Item $f).LastWriteTime
		if (-not $lastWrite -or $w -gt $lastWrite) { $lastWrite = $w }
	}
}
if ($lastWrite) { $silentFor = [int](((Get-Date) - $lastWrite).TotalSeconds) }

"$VersionId : $verdict  prepared=$prepText  inWorld=$(if ($all -match 'Preparing spawn area') { 'yes' } else { 'no' })  " +
	"shaderpack=$shaderPackLoaded  programs=$programs  lithium=$lithiumLoaded  crashes=$crashes  " +
	"threadErrors=$($mine.Count)  disabledMixins=$disabled  conflict=$conflict  " +
	"clientAlive=$(if ($clientAlive) { 'yes' } else { 'no' })  silentFor=$($silentFor)s  " +
	"$(if ($fatal.Count) { ($fatal | Select-Object -Unique) -join ' | ' } else { '-' })"

# --- stop the client, with two independent criteria ---
#
# The ownership check that used to be the ONLY way out of here can never succeed, and that is measured rather than
# suspected: it required the tag to appear on the client's command line, but the client is started as
# `java.exe @<game dir>\java-args.txt` - the tag is one line INSIDE that argfile, so the command line never carries
# it. The OptiLithium launcher states this above its own `$markers` loop, and a process started the same way
# reproduces it exactly: the command line contains the argfile path and does not contain the tag.
#
# Consequence: the client outlived every run. One sweep left 11 clients alive at ~1.5 GB each for nineteen hours,
# and NOTHING about those runs looked wrong, because the verdict is read from the log rather than from the process.
# The first symptom showed up on the NEXT run: a game directory that could not be cleared.
#
# So the client is stopped by:
#
#   1. rig.pid plus the tag (kept: precise whenever it CAN match), and
#   2. anything whose command line names THIS game directory - the same criterion the pre-launch cleanup above
#      already trusts, and the marker the launcher itself recommends (the argfile path is unique per game dir).
#      Only a client started for this run can match: the directory is unique per run and shared with nothing.
$stopped = 0
$tagFile = Join-Path $gameDir 'rig.tag'
$tag = if (Test-Path $tagFile) { (Get-Content $tagFile -Raw).Trim() } else { $null }
$pidFile = Join-Path $gameDir 'rig.pid'
if (Test-Path $pidFile) {
	$targetPid = (Get-Content $pidFile -Raw).Trim()
	$owner = Get-CimInstance Win32_Process -Filter "ProcessId = $targetPid" -ErrorAction SilentlyContinue
	if ($owner -and $tag -and $owner.CommandLine -and $owner.CommandLine.Contains($tag)) {
		cmd /c "taskkill /PID $targetPid /T /F" 2>&1 | Out-Null
		$stopped++
	}
}
foreach ($stray in @(Get-CimInstance Win32_Process -Filter "Name='java.exe'" -ErrorAction SilentlyContinue |
		Where-Object { $_.CommandLine -and $_.CommandLine -like "*$gameDir*" })) {
	cmd /c "taskkill /PID $($stray.ProcessId) /T /F" 2>&1 | Out-Null
	$stopped++
}
if ($stopped) { Write-Host "  stopped $stopped client process(es)" }
