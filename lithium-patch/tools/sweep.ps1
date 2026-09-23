# Builds and tests a patched Lithium for every release, and reports what each one needs.
#
# One pass per release, and the pass is deliberately small: generate the patched jar from that release's
# upstream Lithium, launch it with that release's OptiFabric and OptiFine, and record what happened. Failures are
# expected on the first pass - the point is to collect WHICH mixin each release objects to, so the disabling
# rules can be written down version by version.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File sweep.ps1 -Only 1.21.3 -Seconds 240
param(
	# Comma-separated release name PREFIXES, e.g. '1.21' or '1.21.3,1.21.4'. Empty means everything.
	# Named $Only rather than $Releases on purpose - see the note where the list is built: the harness that
	# drives this project expands variable references inside the command text, so a parameter whose name also
	# appears in that text arrives holding the expanded value instead of what the caller passed.
	[string]$Only = '',
	# Extra Lithium configuration lines applied to every release in this sweep, comma-separated in one argument.
	[string]$LithiumOption = '',
	[int]$Seconds = 240,
	[switch]$NoShader,
	# Skip the launch and only (re)generate the patched jars. Useful to refresh artefacts after a change.
	[switch]$BuildOnly,
	[string]$OutFile
)

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here
# $null = ... on the dot-source, and that is not tidiness.
#
# versions.ps1 ends with a table-literal assignment ("$script:Releases = [ordered]@{ ... }"), and a PowerShell
# assignment is an EXPRESSION: a dot-sourced file therefore returns the assigned object as its output. Without
# the $null, that return value lands in this script's first free slot - the $Releases PARAMETER - so the sweep
# ran with $Releases holding the literal text of the dictionary and then tried to patch a file called
# "System.Collections.Specialized.OrderedDictionary". Suppressing the output is the fix; the parameter keeps the
# value the caller passed.
$null = . (Join-Path $here 'versions.ps1')

if (-not $script:Releases -or -not ($script:Releases -is [System.Collections.IDictionary])) {
	throw "versions.ps1 did not provide a release table (got $(if ($null -eq $script:Releases) { 'null' } else { $script:Releases.GetType().FullName }))"
}

if (-not $OutFile) { $OutFile = Join-Path $here 'sweep-report.txt' }
Remove-Item $OutFile -ErrorAction SilentlyContinue

# A pipeline, NOT @($script:Releases.Keys): wrapping a collection in the array subexpression operator keeps the
# collection as a SINGLE element, so @($coll).Count is 1 and the loop below would run once with the whole
# dictionary as its "release". Piping forces enumeration. That mistake is why this script first announced
# "sweep of 1 release(s)" and then tried to patch a file called
# "System.Collections.Specialized.OrderedDictionary".
# The value is sanitised rather than trusted, because a caller can hand this script a STRINGIFIED collection:
# an OrderedDictionary interpolated into a command line arrives as the literal text
# "System.Collections.Specialized.OrderedDictionary", which is not a release name and would otherwise be looked
# up as one. Anything that is not a plausible release name is discarded, and an empty result falls back to the
# whole table.
# The -Releases parameter is NOT used to build this list, and that is a workaround with a measured cause.
#
# This project is driven from a harness that expands "$name" references inside the COMMAND TEXT before the
# command runs, so any appearance of the release table's name in an argument is replaced by that object cast to
# a string. The symptom was unmistakable: with the table written as "$script:Releases", the parameter arrived
# holding the literal text "System.Collections.Specialized.OrderedDictionary" - and a debug Write-Host that
# merely MENTIONED the table was enough to cause it, which is how the cause was found.
#
# So selection is by prefix instead: -Only 1.21 narrows the sweep to the releases whose name starts with it,
# and nothing in the invocation has to name a variable.
$all = @($script:Releases.Keys | ForEach-Object { [string]$_ })

$requested = @($Only -split ',' |
	ForEach-Object { $_.Trim() } |
	Where-Object { $_ } |
	ForEach-Object { $prefix = $_; $all | Where-Object { $_ -eq $prefix -or $_.StartsWith("$prefix.") } })

$list = if ($requested.Count) { @($requested | Select-Object -Unique) } else { $all }

if ($list.Count -lt 1) { throw "no releases to sweep" }

# A name that is not in the table at all would otherwise fail later as a missing jar, which reads as a broken
# patch rather than as a typo in the request.
foreach ($release in $list) {
	if (-not $script:Releases.Contains($release)) { throw "release '$release' is not in versions.ps1" }
}

"### sweep of $($list.Count) release(s)" | Add-Content $OutFile -Encoding UTF8

foreach ($release in $list) {
	$jars = Get-ReleaseJars -Release $release
	"### $release : lithium=$(Split-Path -Leaf $jars.Lithium) optifabric=$(Split-Path -Leaf $jars.Optifabric)" |
		Add-Content $OutFile -Encoding UTF8

	if ($jars.Foreign) {
		"### $release : NOTE OptiFabric has no build for this release; using $(Split-Path -Leaf $jars.Optifabric), which targets another release" |
			Add-Content $OutFile -Encoding UTF8
	}

	# --- 1. build the patched jar for this release ---
	#
	# Which groups this release needs comes from versions.ps1, so a normal run needs no -LithiumOption at all and
	# every release gets its own measured set. -LithiumOption still overrides that, for probing a different set.
	$releaseOptions = if ($LithiumOption) { @($LithiumOption) } else { Get-LithiumOptions -Release $release }
	$optionsJoined = $releaseOptions -join ','

	$patchArgs = @(
		'-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $here 'patch-lithium.ps1'),
		'-InputJar', $jars.Lithium, '-Version', $release, '-BreaksId', $jars.BreaksId
	)
	if ($optionsJoined) { $patchArgs += @('-LithiumOption', $optionsJoined) }

	$patchOut = & powershell.exe @patchArgs 2>&1
	$patchOut | Add-Content $OutFile -Encoding UTF8

	$patched = Join-Path $root "out\lithium-fabric-mc$release-patched.jar"
	if (-not (Test-Path $patched)) {
		"$release : BUILD FAILED - no patched jar" | Add-Content $OutFile -Encoding UTF8
		continue
	}

	if ($BuildOnly) {
		"$release : BUILT" | Add-Content $OutFile -Encoding UTF8
		continue
	}

	# --- 2. run it ---
	#
	# -NoLithiumConfig on purpose: the switches are baked into the patched jar's own default configuration, so the
	# run proves what a USER gets from the jar alone. Passing them as config/lithium.properties as well would test
	# a configuration file the user would have to install, which is not the deliverable.
	$mods = @($patched, $jars.OptiFabric, $jars.Optifine) -join ','
	$launchArgs = @(
		'-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $here 'launch-rig.ps1'),
		'-VersionId', $jars.Profile, '-GameDirName', "$release-sweep", '-Seconds', "$Seconds",
		'-McVersion', $release, '-Mods', $mods, '-NoLithiumConfig'
	)
	if ($NoShader) { $launchArgs += '-NoShader' }

	$out = & powershell.exe @launchArgs 2>&1
	$line = @($out | Where-Object { $_ -match ' : (IN WORLD|FAILED|NO LAUNCH)' })
	if (-not $line) { $line = @($out | Select-Object -Last 3) }
	$line | Add-Content $OutFile -Encoding UTF8

	# The first mixin failure names the class, and often the group, which is what the next pass needs.
	$log = Join-Path $root "work\$release-sweep\rig-stdout.log"
	$err = Join-Path $root "work\$release-sweep\rig-stderr.log"
	$text = ''
	foreach ($f in @($log, $err)) { if (Test-Path $f) { $text += [string](Get-Content $f -Raw) } }

	foreach ($pattern in @(
		'Mixin apply for mod \S+ failed [^\r\n]{0,160}',
		'Critical injection failure: [^\r\n]{0,200}',
		'InvalidInjectionException[^\r\n]{0,160}',
		'VerifyError[^\r\n]{0,120}'
	)) {
		foreach ($m in ([regex]::Matches($text, $pattern) | Select-Object -First 1)) {
			"    cause: $($m.Value)" | Add-Content $OutFile -Encoding UTF8
		}
	}

	# Which mixin groups this run had to switch off, so the per-version rules stay visible.
	$groups = [regex]::Matches($text, "as rule '([^']+)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
	if ($groups) { "    disabled groups: $($groups -join ', ')" | Add-Content $OutFile -Encoding UTF8 }
}

"### sweep done" | Add-Content $OutFile -Encoding UTF8
Get-Content $OutFile
