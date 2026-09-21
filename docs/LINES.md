# The two release lines

One repository builds both, because the mod is one mod and most of it is namespace independent.

| | obfuscated line | 26.x line |
|---|---|---|
| Releases | 1.20 – 1.21.11 | 26.1.2 |
| Gradle project | root (`fabric-loom`) | `:v26` (`net.fabricmc.fabric-loom`) |
| Build | `gradlew build "-Pmc=<release>"` | `gradlew :v26:build` |
| Names at runtime | intermediary (`class_2586`, `method_11005`) | official (`net/minecraft/world/level/block/entity/BlockEntity`) |
| `mappings` dependency | `net.fabricmc:yarn:<release>:v2` | none — Yarn publishes nothing for 26.1.2 |
| `net.fabricmc:intermediary:<release>` | real mapping artifact | the empty `0.0.0` placeholder |
| Runtime namespace | `intermediary` | `official` |
| Remap step in the pipeline | official → intermediary | skipped outright |
| Java | 17 (1.20–1.20.4) / 21 | 25 |
| Declares `contains_renderer` | yes — Indigo must step aside | no — Indigo registers its own renderer |
| Fixer table used | intermediary ids: `registerFix("class_2586", …)` | official paths: `registerFix("net/minecraft/…/BlockEntity", …)` |

## How one codebase serves both

```
shared/                            Optilithium, OptifineSetup, OptifineInjector, ClassCache,
                                   LambdaRebuilder, OptifineJarFixer, OptifineMappings,
                                   patcher/fixes/** (every fixer), util/**
line/obfuscated/java + resources   MixinTitleScreen, CrashReportMixin (yarn names)
                                   optilithium.mixins.json, fabric.mod.json, assets/
line/official/java + resources     the same two mixins against official names
                                   OptifineFrapiBridge, its own mixin config and fabric.mod.json
v26/                               the Gradle project for the 26.x line
```

The split is possible because **no fixer holds a compiled reference to a game class**. Every class name
inside `shared/.../patcher/fixes` is a string — verified by grepping the directory for `import net.minecraft.`
and getting nothing back. Two consequences:

- both registration tables **compile** on both lines. `registerFix("class_2586", …)` is inert-but-loadable
  on 26.1.2, where its key becomes `net.minecraft.class_2586` and never matches a class name;
- which table is **used** is a runtime decision. `OptifineFixer` asks
  `FabricLoader.getMappingResolver().getCurrentRuntimeNamespace()` and picks accordingly, which is the same
  signal `OptifineSetup` already uses to decide whether to remap at all.

The 26.x `OptifineFrapiBridge` names official types in its own signatures, so it lives on the official side.
The fixer that points at it (`FrapiTesselateBridgeFix`) only mentions it as a **string**
(`"kynarain/cn/optilithium/mod/OptifineFrapiBridge"`) and is therefore shared — it is registered only by the
official table, because the obfuscated table's chunk-rendering repairs use a different route.

`TranslatableText`-style helpers are not the only thing that had to be split: the two `fabric.mod.json` files
differ in the `custom` block, and the two mixin configs in `compatibilityLevel` (`JAVA_17`/`JAVA_21` against
`JAVA_25`).

## What the two lines have in common

- The **`BlockEntity` constructor conflict with Lithium** is identical on both, right down to the Forge
  supertype OptiFine installs, so `RestoreSuperConstructorFix` is shared and only its registration differs.
- `OptifineSetup` needs no change: it detects the namespace and skips the remap when it is `official`.
- The whole test rig in `test/` and the tooling in `tools/` take a profile id and a jar path, and needed only
  the per-release Java level and the `:v26:build` task added.

## Adding a release

- obfuscated line: one line in `build.gradle`'s `yarnBuilds` table (plus `javaVersions` if it predates
  Java 21), then `tools/matrix.ps1` for that release;
- 26.x line: `v26/gradle.properties` holds the single supported release. OptiFine publishes no build for any
  26.x release other than 26.1.2, so there is nothing else to add yet.

The cache directory `.optilithium/<OptiFine version>/` is keyed by the OptiFine version only, so
`CACHE_FORMAT` has to be bumped whenever the produced bytecode changes — otherwise a warm cache is reused and
the fixers never run.
