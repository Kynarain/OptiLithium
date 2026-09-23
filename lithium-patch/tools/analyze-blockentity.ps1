# Names every Lithium mixin that touches BlockEntity (class_2586) and, separately, the candidates that inject into
# its CONSTRUCTOR. The second list is the interesting one.
#
# The target name is a PARAMETER because the namespace changes across the versions this project covers:
#   obfuscated  (1.20 - 1.21.11) : -Target net/minecraft/class_2586            (the default)
#   unobfuscated (26.1.2+)       : -Target net/minecraft/world/level/block/entity/BlockEntity
# Passing the wrong one does not error - it simply finds nothing - so a run that reports "mixins naming the target:
# 0" against a jar you know contains some is a sign the namespace is wrong, not that the jar is clean.
#
# Why: OptiFabric rewrites vanilla classes before Mixin sees them. On a class whose constructor it rewrites, a
# Lithium @Inject aimed at that constructor has no target left to bind to, and Mixin aborts the transformation of
# the whole class ("Delegate constructor lookup failed for @Inject target"). Because a mixin failure is fatal, one
# such mixin takes the client down - the fix is to disable exactly the group it belongs to, in lithium.properties,
# rather than to edit any bytecode.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File analyze-blockentity.ps1 -Jar <patched-or-stock.jar>
param(
	[Parameter(Mandatory = $true)][string]$Jar,
	# The obfuscated name to hunt for. 1.20-1.21.11 use class_2586; 26.1.2 is unobfuscated.
	[string]$Target = 'net/minecraft/class_2586'
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

if (-not (Test-Path $Jar)) { throw "no jar at $Jar" }

# Extracted next to the jar, keyed by jar name, so two analyses never share a directory.
$tmp = Join-Path (Split-Path -Parent $Jar) ('analyze-' + [System.IO.Path]::GetFileNameWithoutExtension($Jar))
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
[System.IO.Compression.ZipFile]::ExtractToDirectory($Jar, $tmp)

$cfg = Join-Path $tmp 'lithium.mixins.json'
if (-not (Test-Path $cfg)) { throw "no lithium.mixins.json in $Jar" }
$j = Get-Content $cfg -Raw | ConvertFrom-Json
$root = Join-Path $tmp ($j.package -replace '\.', '\')

$allTargeting = @()
$ctorInjecting = @()

foreach ($m in $j.mixins) {
	$cls = Join-Path $root (($m -replace '\.', '\') + '.class')
	if (-not (Test-Path $cls)) { continue }
	$txt = [System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes($cls))
	if ($txt -notmatch [regex]::Escape($Target)) { continue }
	$allTargeting += $m

	# A candidate is a mixin that BOTH carries an @Inject annotation AND names a constructor. The two together
	# matter: naming '<init>' alone is not enough, because a mixin that merely calls `new Something()` or `super()`
	# also names it without ever targeting a constructor (util.block_entity_retrieval.LevelMixin is exactly that
	# case, and counting it produced a false candidate on the first version of this script).
	$hasInject = $txt -match 'Lorg/spongepowered/asm/mixin/injection/Inject;'
	$namesCtor = $txt -match [regex]::Escape('<init>')
	if ($hasInject -and $namesCtor) {
		# The group is everything before the last dot: 'util.inventory_change_listening.BlockEntityMixin' belongs
		# to the rule 'mixin.util.inventory_change_listening'.
		$group = 'mixin.' + ($m -replace '\.[^.]+$', '')
		$ctorInjecting += [pscustomobject]@{ mixin = $m; group = $group }
	}
}

"=== $([System.IO.Path]::GetFileName($Jar)) ==="
"target filter : $Target"
"mixins naming the target : $($allTargeting.Count)"
""
"--- CANDIDATES: @Inject + names a constructor (the shape that reports 'Delegate constructor lookup failed') ---"
"    a candidate is not a verdict: it means 'this mixin injects and names <init>', so a run may still pass with it"
"    enabled, and a group is only switched off after a launch proves it is needed."
""
foreach ($x in $ctorInjecting) { "  {0,-80} -> {1}=false" -f $x.mixin, $x.group }
if (-not $ctorInjecting.Count) { "  (none)" }
""
"--- distinct rules these candidates belong to ---"
($ctorInjecting | ForEach-Object { $_.group } | Sort-Object -Unique) | ForEach-Object { "  $_=false" }

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
