# Launches one Fabric profile out of this rig for a bounded time and reports a verdict.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File test\launch.ps1 -VersionId "1.21.1-Fabric 0.19.5"
#
# It reproduces what a launcher does for versions\<id>\<id>.json: merge the inherited parent profile,
# flatten the rule-gated argument entries, substitute the placeholders, and run the main class with the
# profile's own classpath and natives. Then it stops the JVM and reports the acceptance signals rather
# than just "the process started".
#
# Verdict signals:
#   Setting user          - the client reached the title screen
#   Sound engine started  - the sound engine came up
#   Mixin apply failed    - a mixin did not find its target (the failure this project exists to fix)
#   crash report          - written during THIS run (compared against what was there before)
param(
	[string]$VersionId = "1.21.1-Fabric 0.19.5",
	[string]$McRoot = "$env:APPDATA\.minecraft",
	[string]$GameDir,
	[int]$Seconds = 120,
	[string[]]$Mods = @(),
	[string]$JavaHome = "C:\Program Files\Java\jdk-21",
	[int]$MemoryMb = 2048,
	[string[]]$ExtraJvm = @(),
	[string[]]$ExtraGameArgs = @(),
	[switch]$Fresh,
	[switch]$KeepRunning,
	# Start the JVM and return immediately instead of waiting for it. See the note at the launch site.
	[switch]$Detach
)

$ErrorActionPreference = 'Continue'

# '@(...)' rather than a bare list so -Mods 'a;b' and -Mods a,b both work.
$Mods = @($Mods | ForEach-Object { $_ -split ';' } | Where-Object { $_ })

$versionsDir = Join-Path $McRoot 'versions'
$librariesDir = Join-Path $McRoot 'libraries'
$assetsDir = Join-Path $McRoot 'assets'
if (-not $GameDir) { $GameDir = Join-Path (Split-Path -Parent $PSCommandPath) "run\$VersionId" }

$profileFile = Join-Path $versionsDir "$VersionId\$VersionId.json"
if (-not (Test-Path $profileFile)) { throw "no profile at $profileFile" }
$profile = Get-Content $profileFile -Raw | ConvertFrom-Json

$parent = $null
if ($profile.inheritsFrom) {
	$parentFile = Join-Path $versionsDir "$($profile.inheritsFrom)\$($profile.inheritsFrom).json"
	if (-not (Test-Path $parentFile)) { throw "profile inherits $($profile.inheritsFrom) but $parentFile is missing" }
	$parent = Get-Content $parentFile -Raw | ConvertFrom-Json
}

function Test-Rules($rules) {
	if (-not $rules) { return $true }
	$allowed = $false
	foreach ($rule in $rules) {
		$match = $true
		if ($rule.os) {
			if ($rule.os.name -and $rule.os.name -ne 'windows') { $match = $false }
			if ($rule.os.arch -and $rule.os.arch -ne 'x86') { $match = $false }
		}
		# Feature-gated entries (demo mode, custom resolution, quick play) never apply to this rig.
		if ($rule.features) { $match = $false }
		if ($match) { $allowed = ($rule.action -eq 'allow') }
	}
	return $allowed
}

function Expand-Args($entries) {
	$out = New-Object System.Collections.Generic.List[string]
	foreach ($entry in $entries) {
		if ($entry -is [string]) { $out.Add($entry); continue }
		if (-not (Test-Rules $entry.rules)) { continue }
		foreach ($value in @($entry.value)) { $out.Add([string]$value) }
	}
	return $out
}

# --- classpath: parent libraries then child libraries, in file order ---
$libEntries = @()
if ($parent) { $libEntries += $parent.libraries }
$libEntries += $profile.libraries

$classpath = New-Object System.Collections.Generic.List[string]
$nativesNeeded = New-Object System.Collections.Generic.List[object]
$missing = New-Object System.Collections.Generic.List[string]
foreach ($lib in $libEntries) {
	if ($lib.rules -and -not (Test-Rules $lib.rules)) { continue }
	if (-not $lib.name) { continue }

	$parts = $lib.name -split ':'
	if ($parts.Count -lt 3) { continue }
	$groupPath = $parts[0] -replace '\.', '/'
	$artifact = $parts[1]
	$version = $parts[2]
	$classifier = if ($parts.Count -gt 3) { $parts[3] } else { $null }

	$basePath = "$groupPath/$artifact/$version/$artifact-$version"
	if ($classifier) { $basePath = "$basePath-$classifier" }
	$jarPath = Join-Path $librariesDir "$basePath.jar"

	if (Test-Path $jarPath) {
		$classpath.Add($jarPath)
	} elseif ($lib.downloads -and $lib.downloads.artifact -and $lib.downloads.artifact.path) {
		$alt = Join-Path $librariesDir ($lib.downloads.artifact.path -replace '/', '\')
		if (Test-Path $alt) { $classpath.Add($alt) } else { $missing.Add("$($lib.name) -> $alt") }
	} else {
		# Reported rather than skipped silently: a profile assembled from a mix of sources can name a library
		# whose path field is absent AND whose jar is not in the cache, and that shows up only as
		# "ClassNotFoundException: net.fabricmc.loader.impl.launch.knot.KnotClient" from the JVM - the mod
		# loader's own class goes missing without naming the library that carried it.
		$missing.Add("$($lib.name) -> $jarPath")
	}

	# Native classifier jars are unpacked next to the profile in a real install; collect what exists.
	if ($lib.natives -and $lib.natives.windows) {
		$nat = $lib.natives.windows -replace '\$\{arch\}', '64'
		$natPath = Join-Path $librariesDir "$basePath-$nat.jar"
		if (Test-Path $natPath) { $nativesNeeded.Add([pscustomobject]@{ Jar = $natPath; Name = $lib.name }) }
	}
}

# The game jar itself is the profile's own jar (a Fabric profile carries the full client).
$gameJar = Join-Path $versionsDir "$VersionId\$VersionId.jar"
if (-not (Test-Path $gameJar)) { throw "no game jar at $gameJar" }
$classpath.Insert(0, $gameJar)

# --- natives: extract once per version into natives\<VersionId> ---
$nativesDir = Join-Path (Split-Path -Parent $PSCommandPath) "natives\$VersionId"
New-Item -ItemType Directory -Force $nativesDir | Out-Null
foreach ($nat in $nativesNeeded) {
	$stamp = Join-Path $nativesDir ('.stamp-' + ($nat.Name -replace '[:\.]', '_'))
	if (Test-Path $stamp) { continue }
	try {
		Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
		$zip = [System.IO.Compression.ZipFile]::OpenRead($nat.Jar)
		foreach ($entry in $zip.Entries) {
			if ($entry.FullName.EndsWith('/')) { continue }
			if ($entry.FullName.StartsWith('META-INF/')) { continue }
			$target = Join-Path $nativesDir $entry.FullName
			New-Item -ItemType Directory -Force (Split-Path -Parent $target) | Out-Null
			[System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
		}
		$zip.Dispose()
		Set-Content -Path $stamp -Value 'ok'
	} catch {
		Write-Host "  native extract failed for $($nat.Name): $_"
	}
}

# --- game dir ---
if ($Fresh -and (Test-Path $GameDir)) { Remove-Item -Recurse -Force $GameDir }
New-Item -ItemType Directory -Force $GameDir, (Join-Path $GameDir 'mods'), (Join-Path $GameDir 'config') | Out-Null
# options.txt: skip the intro so a run reaches the title screen quickly.
$optionsFile = Join-Path $GameDir 'options.txt'
if (-not (Test-Path $optionsFile)) {
	Set-Content -Path $optionsFile -Value @('onboardAccessibility:false', 'pauseOnLostFocus:false', 'narrator:0') -Encoding UTF8
}

foreach ($mod in $Mods) {
	if (-not (Test-Path $mod)) { Write-Host "  MISSING MOD: $mod"; continue }
	Copy-Item $mod (Join-Path $GameDir 'mods') -Force
}

# --- arguments ---
$jvmEntries = @()
$gameEntries = @()
if ($parent) {
	if ($parent.arguments) { $jvmEntries += $parent.arguments.jvm; $gameEntries += $parent.arguments.game }
	elseif ($parent.minecraftArguments) { $gameEntries += ($parent.minecraftArguments -split ' ') }
}
if ($profile.arguments) { $jvmEntries += $profile.arguments.jvm; $gameEntries += $profile.arguments.game }
elseif ($profile.minecraftArguments) { $gameEntries += ($profile.minecraftArguments -split ' ') }

$jvmArgs = Expand-Args $jvmEntries
$gameArgs = Expand-Args $gameEntries

$assetIndex = if ($profile.assetIndex) { $profile.assetIndex.id } elseif ($parent.assetIndex) { $parent.assetIndex.id } else { 'legacy' }
$mainClass = if ($profile.mainClass) { $profile.mainClass } else { $parent.mainClass }

$substitutions = @{
	'${natives_directory}' = $nativesDir
	'${launcher_name}' = 'optilithium-rig'
	'${launcher_version}' = '1.0'
	'${classpath}' = ($classpath -join ';')
	'${classpath_separator}' = ';'
	'${library_directory}' = $librariesDir
	'${auth_player_name}' = 'RigTest'
	'${version_name}' = $VersionId
	'${game_directory}' = $GameDir
	'${assets_root}' = $assetsDir
	'${assets_index_name}' = $assetIndex
	'${auth_uuid}' = '00000000000000000000000000000001'
	'${auth_access_token}' = '0'
	'${clientid}' = 'rig'
	'${auth_xuid}' = '0'
	'${user_type}' = 'legacy'
	'${version_type}' = 'release'
	'${resolution_width}' = '854'
	'${resolution_height}' = '480'
	'${quickPlayPath}' = (Join-Path $GameDir 'quickPlay')
	'${quickPlaySingleplayer}' = ''
	'${quickPlayMultiplayer}' = ''
	'${user_properties}' = '{}'
	'${profile_name}' = $VersionId
}

function Substitute([string]$text) {
	foreach ($key in $substitutions.Keys) { $text = $text.Replace($key, $substitutions[$key]) }
	return $text
}

$javaExe = Join-Path $JavaHome 'bin\java.exe'
if (-not (Test-Path $javaExe)) { throw "no java at $javaExe" }

$finalArgs = New-Object System.Collections.Generic.List[string]
# A unique marker, so the JVM this script started can be identified again without guessing from the command
# line (the argfile path appears there but with surrounding quotes, which made a -like match unreliable) and
# so that stopping it can never touch a Minecraft window that belongs to somebody else. Both properties go
# into the argfile, so they are not exposed as real system properties to the game itself beyond the string.
$rigTag = 'rig-' + [Guid]::NewGuid().ToString('N').Substring(0, 12)
$finalArgs.Add("-Xmx${MemoryMb}M")
$finalArgs.Add('-Dfile.encoding=UTF-8')
$finalArgs.Add("-Doptilithium.rig.tag=$rigTag")
foreach ($a in $jvmArgs) { $finalArgs.Add((Substitute $a)) }
foreach ($a in $ExtraJvm) { $finalArgs.Add($a) }
$finalArgs.Add($mainClass)
foreach ($a in $gameArgs) { $finalArgs.Add((Substitute $a)) }
foreach ($a in $ExtraGameArgs) { $finalArgs.Add($a) }

# --- run ---
$crashDir = Join-Path $GameDir 'crash-reports'
$before = @()
if (Test-Path $crashDir) { $before = Get-ChildItem $crashDir -File | Select-Object -ExpandProperty Name }

Write-Host "=== launching $VersionId ==="
Write-Host "  java     : $javaExe"
Write-Host "  game dir : $GameDir"
Write-Host "  mods     : $((Get-ChildItem (Join-Path $GameDir 'mods') -File -ErrorAction SilentlyContinue).Name -join ', ')"
Write-Host "  classpath: $($classpath.Count) entries"
if ($missing.Count -gt 0) {
	Write-Host "  MISSING $($missing.Count) librar$(if ($missing.Count -eq 1) { 'y' } else { 'ies' }) - the client will not start:"
	$missing | Select-Object -First 10 | ForEach-Object { Write-Host "    $_" }
}

$stdout = Join-Path $GameDir 'rig-stdout.log'
$stderr = Join-Path $GameDir 'rig-stderr.log'
Remove-Item $stdout, $stderr -ErrorAction SilentlyContinue

# java.exe is started DIRECTLY, with the arguments passed as the raw command-line string
# 'java.exe @"<argfile>"'. Two dead ends are recorded here so they are not tried a third time:
#   - Start-Process -ArgumentList with a quoted path: PowerShell re-quotes/escapes what it joins, so the
#     JDK path's space is not protected and cmd answers "'C:\Program' is not recognized as an internal or
#     external command" while the game never starts;
#   - Start-Process -RedirectStandardOutput: every System.out line written before the game's own log4j
#     console appender comes up is dropped, which is precisely where Fabric Loader's "Loading N mods" and
#     the whole [OptiLithium] preLaunch pipeline write. The log then looks like nothing ever loaded.
# System.Diagnostics.Process with Strings as the arguments and a redirect to a real file has neither
# problem: no shell is involved, so no command-line-length limit and no re-quoting.
$argFile = Join-Path $GameDir 'java-args.txt'
$lines = New-Object System.Collections.Generic.List[string]
foreach ($a in $finalArgs) {
	# JVM argfile quoting: backslash-escape backslashes and double quotes, then wrap in double quotes.
	$escaped = $a -replace '\\', '\\' -replace '"', '\"'
	$lines.Add('"' + $escaped + '"')
}
# Encoding matters: Set-Content -Encoding UTF8 writes a BOM, and 'java @argfile' does NOT strip it, so the
# JVM reads the first argument as "\uFEFF-Xmx2048M" and dies with ClassNotFoundException on it. Written
# BOM-less through UTF8Encoding(false) instead - measured, after a run failed with exactly that error.
[System.IO.File]::WriteAllLines($argFile, $lines, (New-Object System.Text.UTF8Encoding($false)))

$stdout = Join-Path $GameDir 'rig-stdout.log'
$stderr = Join-Path $GameDir 'rig-stderr.log'
Remove-Item $stdout, $stderr -ErrorAction SilentlyContinue

# Started through WMI (Win32_Process.Create), which gives the client no parent and no inherited handles.
#
# Measured, and every rejected form cost a run:
#   - Start-Process -RedirectStandardOutput drops every System.out line written before the game's own log4j
#     console appender exists, which is exactly where Fabric Loader's "Loading N mods" and the whole
#     [OptiLithium] preLaunch pipeline write - the log then looks as if no mod ever loaded;
#   - cmd.exe /c start, and every other form in which the client is still a CHILD of this process: the JVM
#     inherits the harness's console and handle table, so the calling process waits on it. When that process
#     is powershell.exe with redirected output, PowerShell's write-access check then fails with
#     "The process cannot access the file ... because it is being used by another process" once the client
#     itself redirects its stdout to that same file. Reproduced on 1.21.4, 1.21.3, 1.21.6 and 1.20.
# Nothing is lost by detaching: the game's own log carries the mod output, and the launcher-phase lines are
# captured by the '>' redirects in the command line itself.
# The command line goes through cmd.exe, because '>' and '2>' are cmd's redirection and WMI's Create does not
# interpret them. Without the cmd wrapper the JVM receives '>C:\...\rig-stdout.log' as a literal argument,
# starts (a pid is returned), writes neither file and dies with no output at all - which is exactly what a
# 1.20 run did before the wrapper was added. cmd itself is only a launcher here: it exits immediately and the
# client keeps running with no relation to the harness process tree.
#
# The java path is quoted with PLAIN quotes and the whole command with /s-style outer quotes. Backslash-escaping
# the inner quotes the way the JVM's own argfile format does makes cmd treat them as literal characters and
# answer '\"C:\Program Files\Java\jdk-17\bin\java.exe\"' is not recognized as an internal or external command.
$inner = '"' + $javaExe + '" @"' + $argFile + '"'
$command = 'cmd.exe /d /s /c "' + $inner + ' >"' + $stdout + '" 2>"' + $stderr + '""'
$created = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
	CommandLine = $command
	CurrentDirectory = $GameDir
} -ErrorAction SilentlyContinue

if (-not $created -or -not $created.ProcessId) { throw "could not start the client: $($created | Out-String)" }
Start-Sleep -Seconds 2

$procPid = $null
$pidFile = Join-Path $GameDir 'rig.pid'
Set-Content -Path (Join-Path $GameDir 'rig.tag') -Value $rigTag
$deadline = (Get-Date).AddSeconds(25)

# The JVM reads its arguments from the argfile, so the tag does NOT appear on the process command line;
# Get-CimInstance therefore cannot match on it. The argfile path does, and it is unique per game directory.
# Both patterns are tried, and the tag is still recorded for the ownership check in analyze.ps1.
$markers = @($argFile, $rigTag)
while (-not $procPid -and (Get-Date) -lt $deadline) {
	$candidate = Get-CimInstance Win32_Process -Filter "Name = 'java.exe'" -ErrorAction SilentlyContinue |
		Where-Object {
			$cl = $_.CommandLine
			if (-not $cl) { return $false }
			foreach ($m in $markers) { if ($cl.Contains($m)) { return $true } }
			if ($cl -like "*$GameDir*") { return $true }
			return $false
		} | Select-Object -First 1
	if ($candidate) { $procPid = $candidate.ProcessId }
	else { Start-Sleep -Milliseconds 500 }
}

if (-not $procPid) { throw "could not identify the launched JVM for $GameDir (no java.exe carries $argFile)" }
Set-Content -Path $pidFile -Value $procPid
Write-Host "  started pid $procPid"
if ($Detach) {
	Write-Host "  detached; read the result with test\analyze.ps1"
	Write-Host "  stdout: $stdout"
	return
}

$proc = Get-Process -Id $procPid -ErrorAction SilentlyContinue
$deadline = (Get-Date).AddSeconds($Seconds)
while ($proc -and -not $proc.HasExited -and (Get-Date) -lt $deadline) {
	Start-Sleep -Milliseconds 500
	$proc = Get-Process -Id $procPid -ErrorAction SilentlyContinue
}

if ($proc -and -not $proc.HasExited) {
	Write-Host "  stopping after $($Seconds)s (pid $procPid)"
	# taskkill /T as well as Kill: the client may spawn children, and a surviving JVM keeps the window,
	# the GPU and the natives folder, which then poisons the next run of this rig.
	try { & taskkill.exe /PID $procPid /T /F 2>&1 | Out-Null } catch { }
	Start-Sleep -Seconds 3
}

Start-Sleep -Milliseconds 500

$log = ''
if (Test-Path $stdout) { $log = [string](Get-Content $stdout -Raw) }
$errText = ''
if ($null -eq $log) { $log = '' }
if ($null -eq $errText) { $errText = '' }
# The game's own log is appended as well: it is written from inside the JVM, so it survives even when the
# console stream is lost, and a line missing from rig-stdout.log can still be found here.
$latestLog = Join-Path $GameDir 'logs\latest.log'
if (Test-Path $latestLog) { $log += "`n" + [string](Get-Content $latestLog -Raw) }

Write-Host ""
Write-Host "=== verdict ==="
$signals = [ordered]@{
	'Setting user'          = 'reached the title screen'
	'Sound engine started'  = 'sound engine up'
	'Loaded 1 mods'         = 'mod list'
	'[OptiFabric]'          = 'OptiFabric ran'
	'[OptiLithium]'         = 'OptiLithium ran'
	'Mixin apply failed'    = 'A MIXIN DID NOT APPLY'
	'Mixin transformation'  = 'A MIXIN TRANSFORMATION FAILED'
	'Failed to launch'      = 'LOADER REFUSED TO LAUNCH'
	'Incompatible mod set'  = 'LOADER REFUSED TO LAUNCH'
	'NoClassDefFoundError'  = 'missing class'
	'VerifyError'           = 'bytecode rejected'
	'Exception in thread "main"' = 'main thread died'
}
foreach ($key in $signals.Keys) {
	$hits = ([regex]::Matches($log, [regex]::Escape($key))).Count
	if ($hits -gt 0) { Write-Host ("  [{0,4}] {1}  ({2})" -f $hits, $key, $signals[$key]) }
}

$after = @()
if (Test-Path $crashDir) { $after = Get-ChildItem $crashDir -File | Select-Object -ExpandProperty Name }
$newCrashes = $after | Where-Object { $before -notcontains $_ }
if ($newCrashes) { Write-Host "  NEW CRASH REPORTS: $($newCrashes -join ', ')" } else { Write-Host "  no new crash reports" }

Write-Host "  stdout bytes: $($log.Length)   stderr bytes: $($errText.Length)"
if ($errText.Length -gt 0) {
	Write-Host "  --- stderr head ---"
	($errText -split "`n" | Select-Object -First 25) | ForEach-Object { Write-Host "    $_" }
}

# The lines that matter for a mixin/loader failure, so a failing run is diagnosable from the tail alone.
$interesting = ($log -split "`n") | Where-Object {
	$_ -match 'Mixin apply failed|Mixin transformation|Incompatible mod set|Failed to launch|refmap|Caused by|^\s+at net\.minecraft|Critical injection failure|@At|Could not find|InvalidInjectionException|NoSuchMethodError|VerifyError|MixinApplyError'
} | Select-Object -First 60
if ($interesting) {
	Write-Host "  --- interesting log lines ---"
	$interesting | ForEach-Object { Write-Host "    $($_.TrimEnd())" }
}

Write-Host ""
Write-Host "  logs: $stdout"
