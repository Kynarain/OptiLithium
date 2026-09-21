# Creates a Fabric profile for one Minecraft version, so the rig can launch that release.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\make-profile.ps1 -Version 1.20
#
# Only some releases have a hand-made Fabric profile in .minecraft\versions, and the rig has to run every
# release in the matrix. The right way to make the rest is Fabric's OWN installer:
#
#   java -jar fabric-installer.jar client -dir <mcroot> -mcversion <version> -loader 0.19.5
#
# The loader command is not a convenience. An earlier version of this script cloned the nearest existing
# profile and swapped in that release's client jar, which fails in two different ways depending on the pair:
#   - library sets differ across releases, so a 1.21.11 profile carrying 1.21.11's LWJGL/datafixerupper/authlib
#     against a 1.20 client starts and then produces NO output at all;
#   - even within one family, the obfuscation maps differ, so 1.20 built from the 1.20.4 profile dies in
#     Fabric Loader's own remap step:
#       java.lang.RuntimeException: Unfixable conflicts
#         at net.fabricmc.loader.impl.lib.tinyremapper.TinyRemapper.handleConflicts
#         ... Calling MinecraftGameProvider.initialize
#     with "Mapping source name conflicts detected" for names as ordinary as etm METHOD b.
# The installer derives the mappings and the library set for the release it is asked for, so neither can
# happen. It needs the network on first use (it downloads that release's client and mappings).
#
# Cloning is kept only as a fallback for an offline machine, and it warns when it is used.
param(
	[Parameter(Mandatory = $true)][string]$Version,
	[string]$McRoot = "$env:APPDATA\.minecraft",
	[string]$SourceProfile = "",
	[string]$ClientJarDir = "C:\Users\kynar\IdeaProjects\scratch\mcclient",
	[string]$InstallerJar = "C:\Users\kynar\IdeaProjects\scratch\fabric-installer.jar",
	[string]$LoaderVersion = "0.19.5",
	[string]$JavaExe = "C:\Program Files\Java\jdk-21\bin\java.exe",
	[switch]$Force
)

# A duplicate ASM on the classpath is fatal to Fabric Loader ("duplicate ASM classes found on classpath:
# .../asm-9.6.jar!...ClassReader.class, .../asm-9.10.1.jar!...ClassReader.class"). The profiles that ship this
# way carry two copies: an older ASM from the launcher's own Minecraft entry (9.3 on 1.21.3, 9.6 elsewhere)
# and 9.10.1 from Fabric Loader. Loader ships 9.10.1 itself as a launch library, so every other copy is pure
# redundancy - and the version to keep differs per release, which is why this drops all of them rather than
# naming one.
#
# Declared here, at the TOP of the script, because PowerShell only knows a function after the line that
# defines it has run. Defined further down it does not exist yet when the "profile already exists" branch
# calls it, and the call fails with "The term 'Remove-DuplicateAsm' is not recognized" while the script
# carries on and the duplicate survives.
function Remove-DuplicateAsm([string]$jsonPath) {
	if (-not (Test-Path $jsonPath)) { return }

	$doc = Get-Content $jsonPath -Raw | ConvertFrom-Json
	$kept = @()
	$dropped = @()

	foreach ($lib in $doc.libraries) {
		if ($lib.name -match '^org\.ow2\.asm:asm:[\d.]+$' -and $lib.name -ne 'org.ow2.asm:asm:9.10.1') {
			$dropped += $lib.name
			continue
		}

		$kept += $lib
	}

	if ($dropped.Count -eq 0) { return }

	$doc.libraries = $kept
	$doc | ConvertTo-Json -Depth 40 | Set-Content $jsonPath -Encoding UTF8
	Write-Host "  dropped duplicate ASM: $($dropped -join ', ')"
}

$ErrorActionPreference = 'Continue'
$versionsDir = Join-Path $McRoot 'versions'
$targetId = "$Version-Fabric-0.19.5"
$targetDir = Join-Path $versionsDir $targetId

# The vanilla version JSON for a release: from .minecraft\versions when a launcher put it there, otherwise
# straight from Mojang's version manifest. The installer's profile inherits from one of these, and the rig's
# .minecraft has none of them (only profiles somebody made by hand), so it has to be fetched.
function Get-VanillaProfile([string]$id) {
	$local = Join-Path $versionsDir "$id\$id.json"
	if (Test-Path $local) { return Get-Content $local -Raw | ConvertFrom-Json }

	try {
		$manifest = Invoke-RestMethod -Uri 'https://launchermeta.mojang.com/mc/game/version_manifest_v2.json' -TimeoutSec 60
		$entry = $manifest.versions | Where-Object { $_.id -eq $id } | Select-Object -First 1
		if (-not $entry) { throw "no $id in the version manifest" }

		Write-Host "    fetching the vanilla $id profile from Mojang"

		return Invoke-RestMethod -Uri $entry.url -TimeoutSec 60
	} catch {
		Write-Host "    could not get the vanilla $id profile: $_"
		return $null
	}
}

if ((Test-Path (Join-Path $targetDir "$targetId.json")) -and -not $Force) {
	Write-Host "  profile $targetId already exists"
	# Still deduplicated, every time. The check above returns early for a profile that already exists, and a
	# profile can carry two ASM jars without anyone noticing until the client refuses to start: the early
	# return is what let 1.21.3 and 1.21.4 keep asm-9.3 / asm-9.6 next to asm-9.10.1 and fail with
	# "duplicate ASM classes found on classpath" while every other release worked.
	Remove-DuplicateAsm (Join-Path $targetDir "$targetId.json")
	return
}

# --- preferred path: Fabric's own installer ---
if (Test-Path $InstallerJar) {
	Write-Host "  running the Fabric installer for $Version"
	& $JavaExe -jar $InstallerJar client -dir $McRoot -mcversion $Version -loader $LoaderVersion 2>&1 |
		Select-String -Pattern "Loading Fabric Installer|Installing|Creating profile|error|Exception" |
		Select-Object -First 4 | ForEach-Object { Write-Host "    $($_.Line)" }

	# The installer names the profile "fabric-loader-<loader>-<mc>", not "<mc>-Fabric-<loader>", and the
	# profile it writes INHERITS from a vanilla profile ("inheritsFrom": "1.20") that a launcher would have
	# from Mojang's own version list. This rig has no such profile - .minecraft\versions holds only the
	# profiles somebody made - so the inheritance is flattened here into a self-contained profile, which is
	# what test\launch.ps1 reads.
	$installedId = "fabric-loader-$LoaderVersion-$Version"
	$installedDir = Join-Path $versionsDir $installedId
	$installedJson = Join-Path $installedDir "$installedId.json"

	if (Test-Path $installedJson) {
		$profile = Get-Content $installedJson -Raw | ConvertFrom-Json
		$parent = $null

		if ($profile.inheritsFrom) {
			$parent = Get-VanillaProfile $profile.inheritsFrom
		}

		$libraries = @()
		if ($parent) { $libraries += $parent.libraries }
		$libraries += $profile.libraries

		# The arguments have to be MERGED, not chosen. A Fabric profile carries only its own additions - for
		# 1.20 that is a single jvm entry, "-DFabricMcEmu= net.minecraft.client.main.Main" - while every
		# entry that actually builds the classpath and starts the game (--username, --gameDir, -cp,
		# -Djava.library.path, ...) lives in the vanilla profile it inherits from. Taking the child's
		# arguments because they exist produced a profile with a one-entry jvm list and no game arguments at
		# all, and the client then failed with
		#   ClassNotFoundException: net.fabricmc.loader.impl.launch.knot.KnotClient
		# because no classpath was ever passed. The parent's entries come first, so the child's additions win
		# where the JVM takes the last value.
		$jvmArgs = @()
		$gameArgs = @()
		if ($parent -and $parent.arguments) {
			$jvmArgs += $parent.arguments.jvm
			$gameArgs += $parent.arguments.game
		}
		if ($profile.arguments) {
			$jvmArgs += $profile.arguments.jvm
			$gameArgs += $profile.arguments.game
		}

		# Everything the launch needs, combined. The vanilla values win where the child does not override
		# them, because the child only carries what Fabric changes (the main class and its own libraries).
		$flat = [ordered]@{
			id = $targetId
			time = $profile.time
			releaseTime = $profile.releaseTime
			type = 'release'
			mainClass = $profile.mainClass
			arguments = [ordered]@{ game = $gameArgs; jvm = $jvmArgs }
			libraries = $libraries
			assetIndex = if ($parent -and $parent.assetIndex) { $parent.assetIndex } else { $profile.assetIndex }
			assets = if ($parent -and $parent.assets) { $parent.assets } else { $profile.assets }
			javaVersion = if ($parent -and $parent.javaVersion) { $parent.javaVersion } else { $profile.javaVersion }
			downloads = if ($parent -and $parent.downloads) { $parent.downloads } else { $profile.downloads }
			minimumLauncherVersion = 21
			complianceLevel = if ($parent -and $parent.complianceLevel) { $parent.complianceLevel } else { $profile.complianceLevel }
			clientVersion = $Version
		}

		New-Item -ItemType Directory -Force $targetDir | Out-Null
		# The profile's jar IS the client jar. The installer does not write one - its profile inherits from a
		# vanilla profile whose "downloads.client" names it - so it is taken from the rig's own download
		# cache, and fetched from Mojang when that does not have it.
		$clientJar = Get-ChildItem $ClientJarDir -Filter "client-$Version.jar" -ErrorAction SilentlyContinue |
			Select-Object -First 1

		if (-not $clientJar -and $parent -and $parent.downloads.client) {
			$target = Join-Path $ClientJarDir "client-$Version.jar"
			New-Item -ItemType Directory -Force $ClientJarDir | Out-Null
			Write-Host "    downloading the $Version client jar"
			Invoke-WebRequest -Uri $parent.downloads.client.url -OutFile $target -TimeoutSec 600
			$clientJar = Get-Item $target
		}

		if (-not $clientJar) {
			Write-Host "  no client jar for $Version; the profile has no <id>.jar and cannot be launched"
			return
		}

		Copy-Item $clientJar.FullName (Join-Path $targetDir "$targetId.jar") -Force
		$flat | ConvertTo-Json -Depth 40 | Set-Content (Join-Path $targetDir "$targetId.json") -Encoding UTF8

		Write-Host "  created profile $targetId from the installer's $installedId$(if ($parent) { " (flattened over the vanilla $Version profile)" } else { '' })"
		return
	}

	Write-Host "  the installer did not produce $installedId; falling back to cloning"
}

# ---------------- fallback: clone the nearest existing profile ----------------
#
# Only reached when the Fabric installer is unavailable or could not produce its profile. Everything this
# path does has to be derived by hand, and each line below was a separate failure at some point.
$ErrorActionPreference = 'Stop'

# Pick a source profile: an explicit one, or the profile of the release whose LIBRARY SET matches. Cloning
# across a library-set boundary does not work: a profile is self-contained, so one built from 1.21.11 carries
# 1.21.11's libraries (LWJGL, datafixerupper, authlib, the Fabric Loader launch libraries) against another
# release's client jar, and the client then dies with no output at all - measured on 1.20 built from the
# 1.21.11 profile.
#
# The values are PROFILE DIRECTORY NAMES as they actually exist in .minecraft\versions, which are not always
# "<version>-Fabric 0.19.5": 1.20.4's own profile is called "1.20.4-Fabric 0.19.5-OptiFine_I7", and that is
# the nearest one for all four 1.20.x releases below it.
$baseFor = @{
	'1.20'    = @('1.20.4-Fabric 0.19.5-OptiFine_I7', '1.20.1-Fabric 0.19.5')
	'1.20.1'  = @('1.20.1-Fabric 0.19.5')
	'1.20.2'  = @('1.20.4-Fabric 0.19.5-OptiFine_I7', '1.20.1-Fabric 0.19.5')
	'1.20.3'  = @('1.20.4-Fabric 0.19.5-OptiFine_I7', '1.20.1-Fabric 0.19.5')
	'1.20.4'  = @('1.20.4-Fabric 0.19.5-OptiFine_I7')
	'1.20.5'  = @('1.20.6-Fabric 0.19.5', '1.20.6-Fabric 0.19.3')
	'1.20.6'  = @('1.20.6-Fabric 0.19.5', '1.20.6-Fabric 0.19.3')
	'1.21'    = @('1.21.1-Fabric 0.19.5', '1.21-Fabric 0.19.5')
	'1.21.1'  = @('1.21.1-Fabric 0.19.5')
	'1.21.2'  = @('1.21.3-Fabric 0.19.5')
	'1.21.3'  = @('1.21.3-Fabric 0.19.5')
	'1.21.4'  = @('1.21.4-Fabric 0.19.5')
	'1.21.5'  = @('1.21.6-Fabric 0.19.5')
	'1.21.6'  = @('1.21.6-Fabric 0.19.5')
	'1.21.7'  = @('1.21.7-Fabric 0.19.5')
	'1.21.8'  = @('1.21.8-Fabric 0.19.5')
	'1.21.9'  = @('1.21.9-Fabric 0.19.5')
	'1.21.10' = @('1.21.10-Fabric 0.19.5')
	'1.21.11' = @('1.21.11-Fabric 0.19.5')
	'26.1'    = @('26.1.2-Fabric 0.19.5')
	'26.1.1'  = @('26.1.2-Fabric 0.19.5')
	'26.1.2'  = @('26.1.2-Fabric 0.19.5')
}

if (-not $SourceProfile) {
	$candidates = if ($baseFor.ContainsKey($Version)) { $baseFor[$Version] } else { @("$Version-Fabric 0.19.5") }

	foreach ($candidate in $candidates) {
		if (Test-Path (Join-Path $versionsDir "$candidate\$candidate.json")) { $SourceProfile = $candidate; break }
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


$json = Get-Content $sourceJson -Raw | ConvertFrom-Json
$json.id = $targetId
if ($json.PSObject.Properties.Name -contains 'inheritsFrom') { $json.PSObject.Properties.Remove('inheritsFrom') }
# The INTERMEDIARY artifact is what makes or breaks a clone, and it is the one field that is not derived from
# the client jar: cloning 1.20 from the 1.20.4 profile leaves "net.fabricmc:intermediary:1.20.4" in place, and
# Fabric Loader then remaps a 1.20 client with 1.20.4's mappings. The failure is not a version-mismatch message
# but this, from the loader's own remap step:
#
#   [WARN] Mapping source name conflicts detected:
#   [WARN] etm METHOD b (()V) -> [exc/method_25346, etm/method_1983, eux/method_52698, evg/method_1437]
#   java.lang.RuntimeException: Unfixable conflicts
#     at net.fabricmc.loader.impl.lib.tinyremapper.TinyRemapper.handleConflicts
#     ... MinecraftGameProvider.initialize
$kept = @()
$dropped = @()
$retargeted = @()

foreach ($lib in $json.libraries) {
	if ($lib.name -match '^org\.ow2\.asm:asm:[\d.]+$' -and $lib.name -ne 'org.ow2.asm:asm:9.10.1') {
		$dropped += $lib.name
		continue
	}

	if ($lib.name -match '^net\.fabricmc:intermediary:(.+)$') {
		$existing = $Matches[1]

		if ($existing -ne $Version) {
			$retargeted += "$existing -> $Version"
			$lib.name = "net.fabricmc:intermediary:$Version"
		}
	}

	$kept += $lib
}

$json.libraries = $kept
if ($dropped.Count -gt 0) { Write-Host "  dropped duplicate ASM: $($dropped -join ', ')" }
if ($retargeted.Count -gt 0) { Write-Host "  retargeted intermediary: $($retargeted -join ', ')" }
# The asset index of the source release is not valid for another one; the game falls back to the newest
# index it can find when the named one is missing, and the rig does not need assets beyond the default.
$json | ConvertTo-Json -Depth 40 | Set-Content (Join-Path $targetDir "$targetId.json") -Encoding UTF8

Write-Host "  created profile $targetId from $SourceProfile (client $($clientJar.Name), $([math]::Round($clientJar.Length/1MB,1)) MB)"
