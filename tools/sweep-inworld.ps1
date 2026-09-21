# Runs tools/in-world.ps1 over a list of releases and appends one result line per release to a report file.
#
# This exists because the harness has no long-lived process: every tool call starts a fresh pwsh, and a
# background job started there dies with that process. Driving a whole sweep from one process is the only way
# to measure several releases without babysitting each one, and a separate result file means a sweep that is
# still running can be read without disturbing it.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\sweep-inworld.ps1 -Versions 1.21.6,1.21.7
param(
	# A comma-separated list as ONE token: '-Versions 1.21.6,1.21.7'. Deliberately typed [string] and not
	# [string[]], because a caller that goes through a shell wrapper does not always get array semantics and
	# "1.21.6,1.21.7,1.20" then binds as a single version name - which is exactly how a batch of seven
	# releases turned into one lookup for a jar called "OptiLithium-1.0.0+mc1.21.6,1.21.7,...,1.21.11.jar".
	[Parameter(Mandatory = $true)][string]$Versions,
	# Neutral-world baseline instead of the modded run: same release, no mods, to tell a mod defect apart from
	# a rig or world problem.
	[switch]$Baseline,
	# Which mods a baseline run installs: none | mine | of | all. 'of' answers "does OptiFine alone fail this
	# way", which is the only way to tell our pipeline's fault from OptiFine's own.
	[string]$BaselineMods = 'none',
	# Also install a shader pack in a baseline run. OptiFine's shader path only runs with a pack present, so a
	# pack-less baseline can pass while the real configuration dies during game initialisation.
	[switch]$Shader,
	[string]$OutFile = 'C:\Users\kynar\IdeaProjects\optilithium\tools\sweep-report.txt',
	[int]$Seconds = 320
)

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$rows = @()

# The game-directory name has to carry both the mod set and the shader flag, otherwise the pack-less and
# pack-enabled baselines share a directory and the second run reports the first one's result.
#
# There is deliberately no "does scratch\optifine exist" guard here. One was added and it rejected a perfectly
# good run ("BaselineMods 'of' requested but scratch\optifine is empty"), because it guessed the scratch path
# from the script location rather than being told it. world-launch.ps1 already fails loudly when a named
# OptiFine jar is missing, and that check knows the real path - a second, weaker copy only added a way to be
# wrong, and it cost a whole baseline round before being noticed.
$baseSuffix = "$BaselineMods$(if ($Shader) { '+shader' } else { '' })"

foreach ($v in ($Versions -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
	$started = Get-Date
	"### $v started $($started.ToString('HH:mm:ss'))" | Add-Content $OutFile -Encoding UTF8
	$out = if ($Baseline) {
		# Not named $args: that is a PowerShell automatic variable, and assigning to it is a trap that silently
		# changes what an enclosing script receives.
		$child = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $here 'world-launch.ps1'),
			'-VersionId', "$v-Fabric-0.19.5", '-GameDirName', "$v-base-$baseSuffix", '-Seconds', "$Seconds", '-Mods', $BaselineMods)
		if ($Shader) { $child += '-Shader' }
		& powershell.exe @child 2>&1
	} else {
		& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'in-world.ps1') `
			-Version $v -Seconds $Seconds 2>&1
	}
	$line = @($out | Where-Object { $_ -match '^[0-9].* : ' -or $_ -match ' IN WORLD | FAILED | NO LAUNCH' })
	if (-not $line) { $line = @($out | Select-Object -Last 25) }
	$rows += $line
	$line | ForEach-Object { $_ | Add-Content $OutFile -Encoding UTF8 }
	"### $v finished $((Get-Date).ToString('HH:mm:ss')) after $([int]((Get-Date) - $started).TotalSeconds)s" | Add-Content $OutFile -Encoding UTF8
}

"===== SWEEP COMPLETE =====" | Add-Content $OutFile -Encoding UTF8
$rows
