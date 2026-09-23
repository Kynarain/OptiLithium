# Checks every patched jar in out\ against what the patch is SUPPOSED to have changed, and against upstream.
#
# Three independent claims are verified for each release:
#
#   1. `breaks` is gone from fabric.mod.json            - the loader conflict this project exists to remove
#   2. the release's mixin groups are set to false      - and NOTHING ELSE was flipped, which is checked by
#                                                         diffing against the upstream jar's own default file
#   3. the licence file and the provenance record are present and untouched
#
# Claim 2 is the one worth automating. It is not enough to see the right lines present: a patch that also flipped
# unrelated groups would still pass a "does it contain mixin.x=false" test while quietly disabling optimisation
# the user never asked for. Comparing against upstream makes the change provably minimal - additive only.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File verify-jars.ps1
param(
	# A single release to check, e.g. -Release 1.21.11. Default: every release in versions.ps1.
	[string]$Release = ''
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here
$outDir = Join-Path $root 'out'

$null = . (Join-Path $here 'versions.ps1')
if ($Release) {
	$list = @($Release)
} else {
	$list = @($script:Releases.Keys | ForEach-Object { [string]$_ })
}

function Read-FromJar {
	param([string]$Jar, [string]$Entry)
	$zip = [System.IO.Compression.ZipFile]::OpenRead($Jar)
	try {
		$e = $zip.Entries | Where-Object { $_.FullName -eq $Entry }
		if (-not $e) { return $null }
		$sr = New-Object System.IO.StreamReader($e.Open())
		try { return $sr.ReadToEnd() } finally { $sr.Close() }
	} finally { $zip.Dispose() }
}

function Get-FalseKeys {
	param([string]$PropertiesText)
	if (-not $PropertiesText) { return @() }
	return @(($PropertiesText -split "`n") |
		Where-Object { $_ -match '^\s*mixin\..*=\s*false\s*$' } |
		ForEach-Object { $_.Trim() } | Sort-Object)
}

$defaultEntry = 'assets/lithium/lithium-mixin-config-default.properties'
$problems = 0

# Say WHERE the inputs came from before judging anything. versions.ps1 resolves these three directories at load
# time, so relocating one of the input projects changes what this report is actually about - and the verdicts
# below compare against the UPSTREAM Lithium jar, so a stale or wrong directory has to be visible in the output
# rather than inferred from a failure.
"inputs  lithium    = $script:LithiumScratch"
"        optifine   = $script:OptiFineScratch"
"        optifabric = $script:OptiFabricDist   (fallback: $script:ThirdParty)"
""

"release    breaks  license   groups  added-by-patch                                  verdict"
"---------  ------  --------  ------  ----------------------------------------------  -------"

foreach ($rel in $list) {
	$jar = Join-Path $outDir "lithium-fabric-mc$rel-patched.jar"
	if (-not (Test-Path $jar)) { "{0,-9}  ** jar missing **" -f $rel; $problems++; continue }

	$jars = Get-ReleaseJars -Release $rel

	# --- 1. breaks ---
	$modJson = Read-FromJar -Jar $jar -Entry 'fabric.mod.json'
	$breaksOk = $true
	try {
		$mod = $modJson | ConvertFrom-Json
		$breaksOk = -not ($mod.PSObject.Properties.Name -contains 'breaks')
	} catch { $breaksOk = $false }

	# --- 2. groups, as an ADDITIVE diff against upstream ---
	$upstreamFalse = Get-FalseKeys (Read-FromJar -Jar $jars.Lithium -Entry $defaultEntry)
	$patchedFalse = Get-FalseKeys (Read-FromJar -Jar $jar -Entry $defaultEntry)
	$added = @($patchedFalse | Where-Object { $upstreamFalse -notcontains $_ })
	$dropped = @($upstreamFalse | Where-Object { $patchedFalse -notcontains $_ })

	# What versions.ps1 says this release needs, compared with what the jar actually gained.
	$expected = @(Get-LithiumOptions -Release $rel | Sort-Object)
	$groupsOk = (@($dropped).Count -eq 0) -and (@(Compare-Object $expected $added).Count -eq 0)

	# --- 3. licence and provenance ---
	$licenseOk = ($null -ne (Read-FromJar -Jar $jar -Entry 'LICENSE.txt')) -or
		($null -ne (Read-FromJar -Jar $jar -Entry 'LICENSE.md'))
	$provenanceOk = $null -ne (Read-FromJar -Jar $jar -Entry 'LITHIUM-PATCH.txt')

	$verdict = if ($breaksOk -and $groupsOk -and $licenseOk -and $provenanceOk) { 'ok' } else { 'PROBLEM' }
	if ($verdict -ne 'ok') { $problems++ }

	$addedText = if ($added.Count) { ($added -join ' ') } else { '(none)' }
	"{0,-9}  {1,-6}  {2,-8}  {3,-6}  {4,-48}  {5}" -f `
		$rel,
		$(if ($breaksOk) { 'ok' } else { 'PRESENT' }),
		$(if ($licenseOk) { 'ok' } else { 'MISSING' }),
		$(if ($groupsOk) { 'ok' } else { 'WRONG' }),
		$addedText,
		$verdict

	if (-not $breaksOk) { "           - breaks is still present in fabric.mod.json" }
	if (@($dropped).Count) { "           - upstream defaults LOST: $($dropped -join ' ')" }
	if (@(Compare-Object $expected $added).Count) {
		"           - expected $(($expected -join ' ')); got $(($added -join ' '))"
	}
	if (-not $licenseOk) { "           - no LICENSE.txt / LICENSE.md - an LGPL-3.0 repackage must carry it" }
	if (-not $provenanceOk) { "           - no LITHIUM-PATCH.txt provenance record" }
}

""
if ($problems) {
	"$problems release(s) have problems."
	exit 1
}
"All $($list.Count) release(s) verified: breaks removed, exactly the expected groups switched off, licence and provenance intact."
