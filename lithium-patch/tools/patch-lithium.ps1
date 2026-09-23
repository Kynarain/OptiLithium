# Rewrites an upstream Lithium jar into one that can load next to OptiFabric.
#
# WHY THIS EXISTS
#
# Lithium declares, in its own fabric.mod.json:
#
#   "breaks": { "optifabric": "*" }
#
# Fabric Loader's solver matches that by MOD ID, so the launch stops before a single class is loaded:
#
#   [main/INFO]: Immediate reason: [NEG_HARD_DEP lithium ... {breaks optifabric @ [*]}, ...]
#
# There is no loader-side escape hatch. config/fabric_loader_dependencies.json can only add, remove or replace a
# mod's DEPENDENCIES; a `breaks` entry naming a mod that is present is a hard conflict. The other direction is
# fine - the OptiFabric jars in this workspace do not break Lithium (verified: 1.1.2+mc1.21.11 declares
# breaks for no_fog, thallium, xradiation and ryoamiclights, and not for lithium) - so the incompatibility is
# one-sided and can be fixed on this side.
#
# WHAT IT CHANGES, AND WHAT IT DELIBERATELY DOES NOT
#
#   1. removes the `breaks` entry naming a given mod id (default: optifabric)
#   2. switches off the mixin groups that cannot survive OptiFine's rewrite, by setting them to false in the jar's
#      OWN default configuration. Lithium carries a default configuration at
#      assets/lithium/lithium-mixin-config-default.properties, and its plugin loads that first and then applies
#      config/lithium.properties on top, so a value baked into the jar takes effect with no user file at all. The
#      plugin reports each one ("Force-disabling mixin '...' as rule '...' disables it and children"), so the
#      effect is verifiable in the log rather than assumed.
#
#      This is why the fix is a CONFIGURATION and not a code change: the rule is Lithium's own supported way to
#      turn a mixin off, mixin classes stay byte-identical, and the whole patch is reproducible on the next
#      upstream release. (An earlier version of this script only emitted config/lithium.properties beside the
#      jar, which made the user responsible for installing it; the jar in the box now works on its own.)
#   3. nothing else. Mixin classes are left byte-identical.
#
# LICENCE. Lithium is LGPL-3.0-only (verified in the jar: `license: LGPL-3.0-only`, plus LICENSE.txt inside).
# Redistributing a modified Lithium means carrying the licence and offering the corresponding source, so this
# script keeps LICENSE.txt in the output unchanged, records exactly what was modified in a provenance file
# inside the jar, and takes -SourceUrl/-SourcePath so the build can point at the source it was made from.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File patch-lithium.ps1 -InputJar <upstream.jar> -Version 1.21
param(
	# The upstream Lithium jar to rewrite.
	[Parameter(Mandatory = $true)][string]$InputJar,
	# The Minecraft release this build targets; used in the output file name and in the provenance record.
	[Parameter(Mandatory = $true)][string]$Version,
	# The mod id Lithium refuses to load with. Defaults to the 1.21.x line's id; the 26.x line renamed itself to
	# optifabric_reforged, so pass that when building for 26.1.2.
	[string]$BreaksId = 'optifabric',
	# Extra ids to remove from `breaks`, comma-separated. Use when the loader reports a second conflict.
	[string]$AlsoBreaks = '',
	# Lines to merge into config/lithium.properties, comma-separated. See the note above on why this is the
	# preferred way to switch a conflicting mixin off.
	[string]$LithiumOption = '',
	# Where the output jar goes. Defaults to out\ beside this script.
	[string]$OutDir,
	# Corresponding source for this build, recorded inside the jar. LGPL-3.0 wants the offer to be real.
	[string]$SourceUrl = 'https://github.com/CaffeineMC/lithium-fabric',
	[string]$SourcePath = ''
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here

if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
New-Item -ItemType Directory -Force $OutDir | Out-Null

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

if (-not (Test-Path $InputJar)) { throw "no input jar at $InputJar" }

$inName = Split-Path -Leaf $InputJar
$outPath = Join-Path $OutDir "lithium-fabric-mc$Version-patched.jar"
if (Test-Path $outPath) { Remove-Item $outPath -Force }

$remove = @($BreaksId) + @($AlsoBreaks -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })

# --- read the input into memory, so the rewrite is one pass and cannot half-write the output ---
$entries = [ordered]@{}
$zip = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path $InputJar).Path)
try {
	foreach ($e in $zip.Entries) {
		if ($e.FullName.EndsWith('/')) { continue }
		$ms = New-Object System.IO.MemoryStream
		$s = $e.Open()
		$s.CopyTo($ms)
		$s.Close()
		$entries[$e.FullName] = $ms.ToArray()
		$ms.Dispose()
	}
} finally {
	$zip.Dispose()
}

# --- 1. the mod metadata: drop the `breaks` entries, then check what is left ---
if (-not $entries.Contains('fabric.mod.json')) { throw "$inName has no fabric.mod.json, so it is not a mod jar" }

$modJson = [System.Text.Encoding]::UTF8.GetString($entries['fabric.mod.json'])
$mod = $modJson | ConvertFrom-Json

$removed = @()
if ($mod.PSObject.Properties.Name -contains 'breaks' -and $mod.breaks) {
	foreach ($id in $remove) {
		if ($mod.breaks.PSObject.Properties.Name -contains $id) {
			$mod.breaks.PSObject.Properties.Remove($id)
			$removed += $id
		}
	}

	# An empty `breaks` object is legal but noisy; drop it so the loader never has to consider it.
	if (@($mod.breaks.PSObject.Properties).Count -eq 0) { $mod.PSObject.Properties.Remove('breaks') }
}

if ($removed.Count -eq 0) {
	Write-Host "[patch-lithium] WARNING: none of $($remove -join ', ') were listed in $inName's breaks; nothing to remove."
	Write-Host "[patch-lithium]          Breaking list present: $(@($mod.breaks.PSObject.Properties.Name) -join ', ')"
}

# Pretty-print with the same 2-space shape the rest of the manifest uses, so a diff against upstream is small.
$json = $mod | ConvertTo-Json -Depth 32

# ConvertTo-Json escapes some characters the manifest does not need escaped; keep it readable.
$json = $json -replace '\\u003c', '<' -replace '\\u003e', '>' -replace '\\u0026', '&'
$entries['fabric.mod.json'] = [System.Text.Encoding]::UTF8.GetBytes($json)

# --- 2. the Lithium configuration: baked into the jar's own defaults, so the jar works with no user file ---
#
# Lithium's mixin plugin reads, in order:
#   assets/lithium/lithium-mixin-config-default.properties   (inside the jar)
#   config/lithium.properties                               (relative to the GAME directory, applied on top)
# so setting the conflicting groups to false in the shipped default is enough on its own: a fresh game directory
# still gets the fix. A user who wants a group back can still turn it on in config/lithium.properties.
$optionLines = @($LithiumOption -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$appliedOptions = @()

$defaultsName = 'assets/lithium/lithium-mixin-config-default.properties'
if ($optionLines.Count) {
	if (-not $entries.Contains($defaultsName)) {
		throw "$inName has no $defaultsName, so the mixin switches cannot be applied. This build needs a Lithium release that ships the default configuration file."
	}

	$defaults = [System.Text.Encoding]::UTF8.GetString($entries[$defaultsName]) -split "`r?`n"
	$out2 = New-Object System.Collections.Generic.List[string]
	$seen = @{}

	foreach ($line in $defaults) {
		$t = $line.Trim()
		# Rewrite in place when the key is already there, so the file keeps its shape and its ordering.
		#
		# The key is taken from the match object and held in $key. Reading $Matches[1] directly here would be a
		# bug: any nested script block that matches - including a Where-Object filter - overwrites $Matches, and
		# the value read afterwards is then the INNER match's first group. That is what produced a file whose
		# lines read "m" instead of "mixin.…=false" the first time this ran.
		$keyMatch = [regex]::Match($t, '^([A-Za-z0-9_.]+)\s*=')
		if ($keyMatch.Success) {
			$key = $keyMatch.Groups[1].Value
			$wanted = $null
			foreach ($opt in $optionLines) {
				if ($opt -match ("^" + [regex]::Escape($key) + "\s*=")) { $wanted = $opt; break }
			}
			if ($wanted) {
				$out2.Add($wanted); $seen[$key] = $true; $appliedOptions += $wanted
			} else {
				$out2.Add($line)
			}
		} else {
			$out2.Add($line)
		}
	}

	# A key that upstream does not have (renamed or newly added group) is appended rather than silently dropped.
	foreach ($opt in $optionLines) {
		$key = ($opt -split '=')[0].Trim()
		if (-not $seen.ContainsKey($key)) {
			$out2.Add($opt); $appliedOptions += $opt
			Write-Host "[patch-lithium] NOTE: '$key' was not in the upstream default file; appended."
		}
	}

	# Lithium logs a line per rule, so record what should be disabled for the verification step to compare against.
	$entries[$defaultsName] = [System.Text.Encoding]::UTF8.GetBytes(($out2 -join "`n"))
	Write-Host "[patch-lithium] baked into $defaultsName : $($appliedOptions -join ' | ')"
}

# --- 3. provenance: exactly what was changed, and where the source is ---
#
# The licence file was renamed upstream (LICENSE.txt in 1.21, LICENSE.md in newer builds), so the record names
# whichever one is actually in this jar instead of assuming.
$licenseName = @($entries.Keys | Where-Object { $_ -match '^LICENSE\.(txt|md)$' } | Sort-Object)
$licenseName = if ($licenseName.Count) { $licenseName[0] } else { '(no LICENSE file found - investigate)' }

$provenance = @(
	"Lithium, repackaged by lithium-patch for Minecraft $Version",
	"",
	"Upstream file : $inName",
	"Target        : $Version",
	"Source        : $SourceUrl"
)
if ($SourcePath) { $provenance += "Source on disk: $SourcePath" }
$provenance += @(
	"Original sha256: $((Get-FileHash (Resolve-Path $InputJar).Path -Algorithm SHA256).Hash.ToLower())",
	"Patched  sha256: (this file)",
	"",
	"Changes made by lithium-patch:",
	"  1. fabric.mod.json: removed the 'breaks' entry for $(if ($removed.Count) { $removed -join ', ' } else { '(none)' })",
	"     Reason: Fabric Loader matches 'breaks' by mod id, so its presence refuses the whole launch. See",
	"     tools/patch-lithium.ps1 for the loader behaviour that makes this necessary.",
	"  2. $defaultsName : set the following mixin groups to false:"
)
# Appended one by one rather than as a nested array, so the record reads as a plain list of lines.
foreach ($o in $appliedOptions) { $provenance += "       $o" }
if (-not $appliedOptions.Count) { $provenance += "       (none)" }
$provenance += @(
	"     Reason: OptiFabric rewrites vanilla classes before Mixin sees them, so a Lithium mixin that injects into",
	"     one of the rewritten constructors has no target left and Mixin aborts that class, which is fatal.",
	"     Setting the group to false is Lithium's own supported switch for this; the mixin classes themselves are",
	"     untouched, so the whole change is a configuration and not a fork.",
	"  3. No class file was modified. Every mixin is byte-identical to upstream.",
	"",
	"Lithium is licensed LGPL-3.0-only. This repackage keeps its LICENSE file ($licenseName) unchanged and is",
	"distributed under the same licence; the corresponding source is the upstream release named above, plus this",
	"script's metadata and configuration-default changes, which are reproduced in full by re-running",
	"tools/patch-lithium.ps1 on the same input."
)
$entries['LITHIUM-PATCH.txt'] = [System.Text.Encoding]::UTF8.GetBytes(($provenance -join "`r`n"))

# --- write the output jar ---
$fs = [System.IO.File]::Open($outPath, [System.IO.FileMode]::CreateNew)
$out = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
try {
	foreach ($name in $entries.Keys) {
		$entry = $out.CreateEntry($name, [System.IO.Compression.CompressionLevel]::Optimal)
		$es = $entry.Open()
		$es.Write($entries[$name], 0, $entries[$name].Length)
		$es.Close()
	}
} finally {
	$out.Dispose()
	$fs.Dispose()
}

# Beside the jar as well, as a reference copy. The jar's own defaults already carry these lines, so this file is
# for a user who wants to see or re-apply them, not something the game needs.
if ($optionLines.Count) {
	$cfgPath = Join-Path $OutDir "lithium-$Version.properties"
	[System.IO.File]::WriteAllLines($cfgPath, [string[]]$optionLines, (New-Object System.Text.UTF8Encoding($false)))
	Write-Host "[patch-lithium] reference copy for $Version -> $cfgPath"
}

Write-Host "[patch-lithium] $inName -> $outPath"
Write-Host "[patch-lithium] removed breaks: $(if ($removed.Count) { $removed -join ', ' } else { 'none' })"
if ($appliedOptions.Count) { Write-Host "[patch-lithium] mixin groups off by default: $($appliedOptions -join ' | ')" }
