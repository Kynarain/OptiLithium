# One-shot rebrand of the ported OptiFabric 1.21.x tree into OptiLithium.
#
# The rename is not cosmetic. Lithium declares "breaks": {"optifabric": "*"} in its fabric.mod.json, and
# Fabric Loader's solver matches that by MOD ID, so a jar whose id is "optifabric" can never be loaded
# alongside Lithium. A different id is the only way through: the loader only knows ids, not what a mod does.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\rebrand.ps1
param(
	[string]$Root = ""
)

$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }

function Replace-Text([string]$relative, $pairs) {
	$path = Join-Path $Root $relative
	if (-not (Test-Path $path)) { Write-Host "  skip (absent): $relative"; return }
	$text = [System.IO.File]::ReadAllText($path)
	$original = $text
	foreach ($pair in $pairs) { $text = $text.Replace($pair[0], $pair[1]) }
	if ($text -ne $original) {
		[System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))
		Write-Host "  rewrote: $relative"
	} else {
		Write-Host "  unchanged: $relative"
	}
}

# A list of pairs, not a hashtable: PowerShell hashtable keys are CASE-INSENSITIVE, so 'optifabric' and
# 'OptiFabric' collide and the whole literal fails to parse ("Duplicate keys ... are not allowed").
# Order also matters here - the longer/more specific strings must be replaced before their prefixes.
$map = @(
	, @('kynarain.cn.optifabric', 'kynarain.cn.optilithium')
	, @('kynarain/cn/optifabric', 'kynarain/cn/optilithium')
	, @('kynarain\cn\optifabric', 'kynarain\cn\optilithium')
	, @('optifabric.mixins.json', 'optilithium.mixins.json')
	, @('assets/optifabric/', 'assets/optilithium/')
	, @('optifabric.extract', 'optilithium.extract')
	, @('.optifine/', '.optilithium/')
	, @('[OptiFabric/remap]', '[OptiLithium/remap]')
	, @('[OptiFabric]', '[OptiLithium]')
	, @('OptifabricError', 'OptilithiumError')
	, @('OptifabricRuntime', 'OptilithiumRuntime')
	, @('OptifabricSetup', 'OptilithiumSetup')
	, @('Optifabric', 'Optilithium')
	, @('OPTIFABRIC', 'OPTILITHIUM')
	, @('OptiFabric', 'OptiLithium')
	, @('optifabric', 'optilithium')
)

Write-Host "REBRAND: moving package directory"
$srcDir = Join-Path $Root 'src\main\java\kynarain\cn\optifabric'
$dstDir = Join-Path $Root 'src\main\java\kynarain\cn\optilithium'
if (Test-Path $srcDir) {
	if (Test-Path $dstDir) { Remove-Item -Recurse -Force $dstDir }
	Move-Item $srcDir $dstDir
	Write-Host "  moved optifabric -> optilithium"
}

Write-Host "REBRAND: renaming files whose NAME carries the old brand"
$renames = @{
	'src\main\java\kynarain\cn\optilithium\Optifabric.java' = 'Optilithium.java'
	'src\main\java\kynarain\cn\optilithium\mod\OptifabricRuntime.java' = 'OptilithiumRuntime.java'
	'src\main\java\kynarain\cn\optilithium\mod\OptifabricSetup.java' = 'OptilithiumSetup.java'
	'src\main\java\kynarain\cn\optilithium\mod\OptifabricError.java' = 'OptilithiumError.java'
	'src\main\resources\optifabric.mixins.json' = 'optilithium.mixins.json'
}
foreach ($from in $renames.Keys) {
	$src = Join-Path $Root $from
	if (Test-Path $src) {
		Move-Item $src (Join-Path $Root $renames[$from]) -Force
		Write-Host "  renamed: $from -> $($renames[$from])"
	}
}

Write-Host "REBRAND: asset directory"
$assetSrc = Join-Path $Root 'src\main\resources\assets\optifabric'
$assetDst = Join-Path $Root 'src\main\resources\assets\optilithium'
if (Test-Path $assetSrc) {
	if (Test-Path $assetDst) { Remove-Item -Recurse -Force $assetDst }
	Move-Item $assetSrc $assetDst
	Write-Host "  moved assets/optifabric -> assets/optilithium"
}

Write-Host "REBRAND: rewriting file contents"
$targets = @()
$targets += Get-ChildItem (Join-Path $Root 'src') -Recurse -File -Include *.java, *.json, *.accesswidener -ErrorAction SilentlyContinue
$targets += Get-ChildItem $Root -File -Include *.gradle, *.properties, *.md -ErrorAction SilentlyContinue
foreach ($file in $targets) {
	$relative = $file.FullName.Substring($Root.Length + 1)
	Replace-Text $relative $map
}

Write-Host "REBRAND: done"
