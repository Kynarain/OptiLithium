# Creates a Fabric profile for one Minecraft version by cloning an existing one and swapping the game jar.
#
# Why this is needed: only some releases have a hand-made Fabric profile in .minecraft\versions (1.20.1,
# 1.20.4, 1.20.6, 1.21, 1.21.1, 1.21.3 ... 1.21.11, 26.1.2). The rig has to run all 22 releases, so the rest
# are derived here. A Fabric profile is self-contained - its <id>.jar IS the full client and it inherits from
# nothing - so cloning one and replacing the jar plus the few version-specific fields is enough.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\make-profile.ps1 -Version 1.20
param(
	[Parameter(Mandatory = $true)][string]$Version,
	[string]$McRoot = "$env:APPDATA\.minecraft",
	[string]$SourceProfile = "",
	[string]$ClientJarDir = "C:\Users\kynar\IdeaProjects\scratch\mcclient",
	[switch]$Force
)

$ErrorActionPreference = 'Stop'
$versionsDir = Join-Path $McRoot 'versions'
$targetId = "$Version-Fabric-0.19.5"
$targetDir = Join-Path $versionsDir $targetId

if ((Test-Path $targetDir) -and -not $Force) {
	Write-Host "  profile $targetId already exists"
	return
}

# Pick a source profile: an explicit one, or the Fabric 0.19.5 profile of the release whose LIBRARY SET
# matches. Cloning across a library-set boundary does not work: a profile is self-contained, so one built
# from 1.21.11 carries 1.21.11's libraries (LWJGL, datafixerupper, authlib, the Fabric Loader launch
# libraries) against another release's client jar, and the client then dies with no output at all - measured
# on 1.20 built from the 1.21.11 profile. Each row below therefore names the nearest release that has a
# hand-made profile of its own.
$baseFor = @{
	'1.20'    = '1.20.4'
	'1.20.1'  = '1.20.4'
	'1.20.2'  = '1.20.4'
	'1.20.3'  = '1.20.4'
	'1.20.4'  = '1.20.4'
	'1.20.5'  = '1.20.6'
	'1.20.6'  = '1.20.6'
	'1.21'    = '1.21.1'
	'1.21.1'  = '1.21.1'
	'1.21.2'  = '1.21.3'
	'1.21.3'  = '1.21.3'
	'1.21.4'  = '1.21.4'
	'1.21.5'  = '1.21.6'
	'1.21.6'  = '1.21.6'
	'1.21.7'  = '1.21.7'
	'1.21.8'  = '1.21.8'
	'1.21.9'  = '1.21.9'
	'1.21.10' = '1.21.10'
	'1.21.11' = '1.21.11'
	'26.1'    = '26.1.2'
	'26.1.1'  = '26.1.2'
	'26.1.2'  = '26.1.2'
}

if (-not $SourceProfile) {
	$wanted = if ($baseFor.ContainsKey($Version)) { $baseFor[$Version] } else { $Version }
	foreach ($suffix in @('-Fabric 0.19.5', '-Fabric-0.19.5', '-Fabric 0.19.3', '-Fabric 0.18.4')) {
		$dir = Join-Path $versionsDir "$wanted$suffix"
		if (Test-Path (Join-Path $dir "$wanted$suffix.json")) { $SourceProfile = "$wanted$suffix"; break }
	}
}
if (-not $SourceProfile) { throw "no source profile found for $Version" }

$sourceDir = Join-Path $versionsDir $SourceProfile
$sourceJson = Join-Path $sourceDir "$SourceProfile.json"
$sourceJar = Join-Path $sourceDir "$SourceProfile.jar"
if (-not (Test-Path $sourceJson)) { throw "no $sourceJson" }
if (-not (Test-Path $sourceJar)) { throw "no $sourceJar" }

# The client jar for the wanted release, so the profile really is that release.
$clientJar = Get-ChildItem $ClientJarDir -Filter "client-$Version.jar" -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $clientJar) { throw "no client-$Version.jar in $ClientJarDir (download it first)" }

New-Item -ItemType Directory -Force $targetDir | Out-Null
# Only the client jar is copied. Copying the source profile's jar first was pointless: the line below
# overwrites it in every case, and a profile's <id>.jar is exactly its client jar.
Copy-Item $clientJar.FullName (Join-Path $targetDir "$targetId.jar") -Force

$json = Get-Content $sourceJson -Raw | ConvertFrom-Json
$json.id = $targetId
if ($json.PSObject.Properties.Name -contains 'inheritsFrom') { $json.PSObject.Properties.Remove('inheritsFrom') }
# A duplicate ASM on the classpath is fatal to Fabric Loader ("duplicate ASM classes found on classpath:
# .../asm-9.6.jar!...ClassReader.class, .../asm-9.10.1.jar!...ClassReader.class"). The profiles that ship this
# way carry two copies: an older ASM from the launcher's own Minecraft entry (9.3 on 1.21.3, 9.6 elsewhere)
# and 9.10.1 from Fabric Loader. Loader ships 9.10.1 itself as a launch library, so every other copy is pure
# redundancy - and the version to keep differs per release, which is why this drops all of them rather than
# naming one.
$kept = @()
$dropped = @()

foreach ($lib in $json.libraries) {
	if ($lib.name -match '^org\.ow2\.asm:asm:[\d.]+$' -and $lib.name -ne 'org.ow2.asm:asm:9.10.1') {
		$dropped += $lib.name
		continue
	}

	$kept += $lib
}

$json.libraries = $kept
if ($dropped.Count -gt 0) { Write-Host "  dropped duplicate ASM: $($dropped -join ', ')" }
# The asset index of the source release is not valid for another one; the game falls back to the newest
# index it can find when the named one is missing, and the rig does not need assets beyond the default.
$json | ConvertTo-Json -Depth 40 | Set-Content (Join-Path $targetDir "$targetId.json") -Encoding UTF8

Write-Host "  created profile $targetId from $SourceProfile (client $($clientJar.Name), $([math]::Round($clientJar.Length/1MB,1)) MB)"
