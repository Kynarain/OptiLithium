# Reads a finished (or still running) rig run out of its game directory and prints the verdict.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -Command "& { . 'test\analyze.ps1' -VersionId '1.21.1-Fabric-0.19.5' }"
#
# This is separate from test\launch.ps1 because the client is GUI-subsystem and its inherited handles keep a
# foreground parent waiting long after the game exits. Splitting "start it" from "read the result" means the
# harness never blocks a tool call on the JVM.
param(
	[string]$VersionId = "1.21.1-Fabric-0.19.5",
	[string]$GameDir,
	[switch]$StopFirst,
	[int]$MaxInteresting = 80,
	# Print every line matching this regex instead of the standard interesting set.
	[string]$Grep
)

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $GameDir) { $GameDir = Join-Path $here "run\$VersionId" }

if ($StopFirst) {
	$pidFile = Join-Path $GameDir 'rig.pid'
	if (Test-Path $pidFile) {
		$targetPid = (Get-Content $pidFile -Raw).Trim()
		$tagFile = Join-Path $GameDir 'rig.tag'
		$tag = if (Test-Path $tagFile) { (Get-Content $tagFile -Raw).Trim() } else { $null }
		# Guard: only ever stop the JVM this rig started, identified by the unique tag its launch put on the
		# command line. A broad 'stop every java.exe' cleanup once killed a Minecraft window that belonged to
		# the user and had nothing to do with this rig, so the check is by tag, not by name.
		$owner = Get-CimInstance Win32_Process -Filter "ProcessId = $targetPid" -ErrorAction SilentlyContinue
		if ($owner -and $tag -and $owner.CommandLine -and $owner.CommandLine.Contains($tag)) {
			Write-Host "  stopping rig pid $targetPid"
			try { & taskkill.exe /PID $targetPid /T /F 2>&1 | Out-Null } catch { }
			Start-Sleep -Seconds 3
		} elseif ($owner) {
			Write-Host "  NOT stopping pid ${targetPid}: it does not carry this rig's tag"
		} else {
			Write-Host "  pid $targetPid is already gone"
		}
	}
}

$stdout = Join-Path $GameDir 'rig-stdout.log'
$latestLog = Join-Path $GameDir 'logs\latest.log'
$console = Join-Path $GameDir 'console.log'

$log = ''
foreach ($file in @($stdout, $latestLog)) {
	if (Test-Path $file) { $log += "`n" + [string](Get-Content $file -Raw) }
}
if ($null -eq $log) { $log = '' }

Write-Host "=== $VersionId ==="
$modsDir = Join-Path $GameDir 'mods'
if (Test-Path $modsDir) { Write-Host "  mods: $((Get-ChildItem $modsDir -File | Select-Object -ExpandProperty Name) -join ', ')" }
Write-Host "  log bytes: $($log.Length)"

if ($Grep) {
	Write-Host "  --- lines matching /$Grep/ ---"
	($log -split "`n") | Where-Object { $_ -match $Grep } | Select-Object -First $MaxInteresting |
		ForEach-Object { Write-Host "    $($_.TrimEnd())" }
	return
}

Write-Host ""
Write-Host "--- signals ---"
$signals = [ordered]@{
	'Loading '                      = 'loader reached the mod list'
	'[OptiLithium]'                 = 'OptiLithium ran'
	'Setting user'                  = 'TITLE SCREEN reached'
	'Sound engine started'          = 'sound engine up'
	'Mixin apply failed'            = 'A MIXIN DID NOT APPLY'
	'Critical injection failure'    = 'MIXIN INJECTION POINT MISSING'
	'Mixin transformation'           = 'MIXIN TRANSFORMATION FAILED'
	'was not found'                 = 'mixin target not found'
	'Failed to launch'              = 'LOADER REFUSED TO LAUNCH'
	'Incompatible mods found'       = 'LOADER REFUSED TO LAUNCH'
	'Mod resolution failed'         = 'LOADER REFUSED TO LAUNCH'
	'NoClassDefFoundError'          = 'missing class'
	'NoSuchMethodError'             = 'missing method'
	'NoSuchFieldError'              = 'missing field'
	'VerifyError'                   = 'bytecode rejected'
	'AbstractMethodError'           = 'broken interface contract'
	'Exception in thread "main"'    = 'main thread died'
	'---- Minecraft Crash Report'   = 'CRASH REPORT written'
}
foreach ($key in $signals.Keys) {
	$hits = ([regex]::Matches($log, [regex]::Escape($key))).Count
	if ($hits -gt 0) { Write-Host ("  [{0,4}] {1}  ({2})" -f $hits, $key, $signals[$key]) }
}

Write-Host ""
Write-Host "--- OptiLithium pipeline lines ---"
$of = ($log -split "`n") | Where-Object { $_ -match '\[OptiLithium' } | Select-Object -First 25
if ($of) { $of | ForEach-Object { Write-Host "    $($_.TrimEnd())" } } else { Write-Host "    (none)" }

Write-Host ""
Write-Host "--- diagnostics ---"
$interesting = ($log -split "`n") | Where-Object {
	$_ -match 'Mixin apply failed|Critical injection failure|Mixin transformation|InvalidInjectionException|MixinApplyError|Incompatible mods|Mod resolution failed|Failed to launch|refmap|Caused by|NoSuchMethodError|NoSuchFieldError|VerifyError|AbstractMethodError|Could not find|Unable to|@At|target was not found|LVTGeneratorError'
} | Select-Object -First $MaxInteresting
if ($interesting) { $interesting | ForEach-Object { Write-Host "    $($_.TrimEnd())" } } else { Write-Host "    (none)" }

Write-Host ""
Write-Host "  files: rig-stdout.log, logs\latest.log, console.log in $GameDir"
