# OptiLithium

<p align="center">
  <img src="src/main/resources/assets/optilithium/icon.png" alt="OptiLithium" width="128"/>
</p>

[![Minecraft](https://img.shields.io/badge/Minecraft-1.20%20~%2026.1.2-green.svg)](https://www.minecraft.net/)
[![Fabric Loader](https://img.shields.io/badge/Fabric%20Loader-%E2%89%A5%200.19.5-blue.svg)](https://fabricmc.net/)
[![Java](https://img.shields.io/badge/Java-17%20/%2021%20/%2025-orange.svg)](https://adoptium.net/)
[![License](https://img.shields.io/badge/License-MPL--2.0-lightgrey.svg)](LICENSE.txt)

> ⚠️ This port was written and verified with AI assistance (DeepSeek). Be careful with it in production.

**Load OptiFine and Lithium in the same Fabric client.**

OptiLithium is a port of [OptiFabric](https://github.com/Chocohead/OptiFabric) (via
[Kynarain/OptiFabric-Reforged](https://github.com/Kynarain/OptiFabric-Reforged)) whose reason to exist is the
one combination OptiFabric alone cannot give you: OptiFine's rendering together with
[Lithium](https://modrinth.com/mod/lithium)'s game-logic optimisations.

Put OptiFine's jar next to this mod in `mods/`. OptiFine itself is **not** bundled or redistributed.

## Why this is a separate mod and not a patch to OptiFabric

**Lithium refuses to load with OptiFabric, and it does so by mod id.** From Lithium's own `fabric.mod.json`:

```json
"breaks": { "optifabric": "*" }
```

Fabric Loader's solver matches that on the id, not on anything the mod does, so the launch stops before a
single class is loaded:

```
[main/WARN]: Mod resolution failed
[main/INFO]: Immediate reason: [NEG_HARD_DEP lithium 0.15.4+mc1.21.1 {breaks optifabric @ [*]},
                                  ROOT_FORCELOAD_SINGLE lithium 0.15.4+mc1.21.1,
                                  ROOT_FORCELOAD_SINGLE optifabric 1.1.0+mc1.21.1]
[main/ERROR]: Incompatible mods found!
```

There is no loader-side escape hatch. Fabric Loader's `config/fabric_loader_dependencies.json` can only
`add`, `remove` or `replace` a mod's **dependencies**; a `breaks` entry naming another mod that is present is
a hard conflict, and the loader exposes no property to ignore it (`fabric.debug.disableModIds` disables a mod
outright, which is not the same thing).

So OptiLithium carries **its own mod id** (`optilithium`). Loader compares ids, so a differently-named port
of the same mechanism loads next to Lithium with no conflict at all. That is the only reason for the name.

Renaming the id is necessary but not sufficient. Once both mods are actually loaded, Lithium's mixins are
applied to the classes OptiFine's patcher rewrote, and some of those no longer have the shape Lithium asks
for. Those are the real compatibility fixes; they are listed in
[`docs/COMPAT_LITHIUM.md`](docs/COMPAT_LITHIUM.md).

## How it works

```
mods/<OptiFine jar>
        │  ① OptiFine's own optifine.Patcher patches the vanilla client jar
        │  ② LambdaRebuilder: lambdas in patched classes point at methods that moved
        ▼
   patched client jar   (OptiFine's patches + OptiFine's classes)
        │  ③ remap official -> intermediary   (skipped on 26.x, which ships unobfuscated)
        ├── OptiFine's own classes + resources ───────────────────────► game class path
        └── patched net/minecraft/** classes ─────────────────────────► ClassCache
                    │  ④ the fixers repair what OptiFine's recompiler left behind
                    ▼
              Fabric Loader's GameTransformer
                    │  ⑤ Loader asks for ready-made bytecode, BEFORE Mixin runs
                    ▼
              Mixin applies OptiLithium's and Lithium's mixins on top
```

Step ⑤ is what makes compatibility workable at all: what is handed to Loader is Mixin's **input**, not its
output, so another mod's mixins see a class they can still transform. The fixers in step ④ are the same
mechanism OptiFabric uses for Fabric API, applied to the classes Lithium injects into.

| Component | Purpose |
|---|---|
| `OptilithiumRuntime` | whole pipeline: find the jar → patch → repair → register |
| `GameTransformerHook` | injects the patched classes into Loader's game transformer |
| `patcher/fixes/**` | the bytecode fixers, including the Lithium ones |
| `RestoreSuperConstructorFix` | restores a supertype and its `super()` call so delegate-constructor injections have a target |
| `OptifineMappings` / `OptifineJarFixer` | name alignment; repairs OptiFine's own jar |

Intermediate files live in `<game dir>/.optilithium/<OptiFine version>/`. The directory is deliberately not
OptiFabric's `.optifine/`: the cache is keyed only by the OptiFine version, so sharing it would let the two
mods hand each other class caches produced by different pipelines.

## Installation

1. Get the OptiFine build for **exactly** your Minecraft version (table below) and the matching Lithium
   build. Do **not** run OptiFine's installer.
2. Put OptiLithium's jar, OptiFine's jar and Lithium's jar into that Fabric instance's `mods/` folder.
3. Launch the **Fabric** profile. The first start is slower (it runs the whole patch pipeline); later starts
   use the cache.
4. A title screen showing OptiFine's version and OptiFine entries in video settings means it worked.

Do not also install OptiFabric itself: its id conflict with Lithium is the thing this mod exists to avoid,
and two mods both patching at `preLaunch` is not a supported combination.

## Supported releases

OptiFine publishes a build for most of these releases; where it publishes none, the release is listed as
unsupported rather than silently omitted. Both jars must match the release exactly — `OptifineVersion` reads
`MC_VERSION` out of `optifine/Config` and refuses to start on a mismatch.

| Minecraft | Java | OptiFine build | Lithium build | State |
|---|---|---|---|---|
| 1.20 | 17 | `preview_OptiFine_1.20_HD_U_I5_pre5` | `lithium-fabric-mc1.20-0.11.2` | ✅ verified live |
| 1.20.1 | 17 | `OptiFine_1.20.1_HD_U_I6` | `lithium-fabric-mc1.20.1-0.11.4` | ✅ verified live |
| 1.20.2 | 17 | `preview_OptiFine_1.20.2_HD_U_I7_pre1` | `lithium-fabric-mc1.20.2-0.12.0` | ✅ verified live |
| 1.20.3 | 17 | — | `lithium-fabric-mc1.20.3-0.12.1` | OptiFine ships no build |
| 1.20.4 | 17 | `OptiFine_1.20.4_HD_U_I7` | `lithium-fabric-mc1.20.4-0.12.1` | ✅ verified live |
| 1.20.5 | 21 | — | `lithium-fabric-mc1.20.5-0.12.5` | OptiFine ships no build |
| 1.20.6 | 21 | `preview_OptiFine_1.20.6_HD_U_J1_pre18` | `lithium-fabric-mc1.20.6-0.12.5` | ✅ verified live |
| 1.21 | 21 | `preview_OptiFine_1.21_HD_U_J1_pre9` | none usable (see below) | ⚠️ OptiLithium alone: verified live |
| 1.21.1 | 21 | `OptiFine_1.21.1_HD_U_J1` | `lithium-fabric-0.15.4+mc1.21.1` | ✅ verified live |
| 1.21.2 | 21 | — | `lithium-fabric-0.14.6+mc1.21.3` | OptiFine ships no build |
| 1.21.3 | 21 | `OptiFine_1.21.3_HD_U_J2` | `lithium-fabric-0.14.6+mc1.21.3` | ✅ verified live |
| 1.21.4 | 21 | `OptiFine_1.21.4_HD_U_J3` | `lithium-fabric-0.15.3+mc1.21.4` | ✅ verified live |
| 1.21.5 | 21 | — | `lithium-fabric-0.16.3+mc1.21.5` | OptiFine ships no build |
| 1.21.6 | 21 | `preview_OptiFine_1.21.6_HD_U_J6_pre3` | `lithium-fabric-0.17.0+mc1.21.6` | ✅ verified live |
| 1.21.7 | 21 | `preview_OptiFine_1.21.7_HD_U_J6_pre7` | `lithium-fabric-0.18.0+mc1.21.7` | ✅ verified live |
| 1.21.8 | 21 | `preview_OptiFine_1.21.8_HD_U_J6_pre16` | `lithium-fabric-0.18.1+mc1.21.8` | ✅ verified live |
| 1.21.9 | 21 | `preview_OptiFine_1.21.9_HD_U_J7_pre2` | `lithium-fabric-0.19.2+mc1.21.9` | ✅ verified live |
| 1.21.10 | 21 | `preview_OptiFine_1.21.10_HD_U_J7_pre11` | `lithium-fabric-0.20.1+mc1.21.10` | ✅ verified live |
| 1.21.11 | 21 | `OptiFine_1.21.11_HD_U_J9` | `lithium-fabric-0.21.4+mc1.21.11` | ✅ verified live |
| 26.1 | 25 | — | `lithium-fabric-0.24.7+mc26.1.2` | OptiFine ships no build |
| 26.1.1 | 25 | — | `lithium-fabric-0.24.7+mc26.1.2` | OptiFine ships no build |
| 26.1.2 | 25 | `preview_OptiFine_26.1.2_HD_U_K1_pre2` | `lithium-fabric-0.24.7+mc26.1.2` | ✅ verified live |

`tools/matrix-report.md` holds the measured result of every row that could be launched, produced by
`tools/matrix.ps1` itself. **15 of the 16 supported releases are green**: the title screen is reached with
Lithium loaded and 0 failed patched classes.

That matrix stops at the title screen, which is not the same as the mod working — chunk rebuild, block entity
ticking and shader compilation all happen **after** a world loads. The deeper run is recorded in
[`docs/IN_WORLD_VERIFICATION.md`](docs/IN_WORLD_VERIFICATION.md): Minecraft 1.21.11 with OptiFine, Lithium
**and Fabric API**, a real world loaded through `--quickPlaySingleplayer` (`Starting integrated minecraft
server`, `Preparing spawn area`), and a shader pack whose **54 programs compiled** with no shader errors and
no crash.

### The one release that is not green

**1.21 is broken by Lithium, not by OptiLithium.** OptiFine ships `1.21` as HD_U_J1 pre9, and Lithium's newest
build for the 1.21 family is `lithium-fabric-0.15.2+mc1.21.1` — a jar built for **1.21.1**. Its mixins are
applied to the 1.21 client and one of them fails the class it targets:

```
Mixin transformation of net.minecraft.class_2614 failed
Caused by: NoClassDefFoundError: Could not initialize class net.minecraft.class_2246
```

`class_2614` on 1.21 is `HopperBlockEntity`, which **OptiFine does not patch at all** — verified by looking
for it in `.optilithium/<version>/Optifine.classes.gz`, where it is absent, so this is not a patched-class
conflict. With Lithium removed from the same instance, OptiLithium + OptiFine alone reach the title screen on
1.21 (`Prepared 440 patched classes (0 skipped, 0 failed)`, 0 crashes). Since 1.21.1 works and 1.21 sits
between 1.20.6 and 1.21.1, use one of those rather than 1.21.

## Building from source

One repository builds both release lines, and most of the mod is shared between them:

```bash
./gradlew build "-Pmc=1.21.11"   # obfuscated line -> build/libs/OptiLithium-1.0.0+mc1.21.11.jar
./gradlew :v26:build             # 26.x line       -> v26/build/libs/OptiLithium-1.0.0+mc26.1.2.jar
```

```
shared/                            the pipeline: OptifineSetup, OptifineInjector, ClassCache, the fixers
line/obfuscated/java + resources   the obfuscated line's two mixins, mixin config, fabric.mod.json
line/official/java + resources     26.x's equivalents, written against official names
v26/                               the Gradle project that builds the 26.x line out of the two above
```

The split is possible because **no fixer holds a compiled reference to a game class** — every class name
inside `patcher/fixes` is a string (checked with a grep for `import net.minecraft.` over the whole directory).
Both registration tables therefore compile on both lines, and which one is *used* is decided at runtime from
the namespace the game runs in. `docs/LINES.md` has the full comparison.

The version number always travels with the Minecraft version: `<mod_version_base>+mc<release>`. Adding a
release to the obfuscated line is one line in `build.gradle`'s `yarnBuilds` table (plus a Java level in
`javaVersions` when the release predates Java 21).

The development environment is not supported: `gradlew runClient` runs in the `named` namespace and would
need an extra mapping layer, so the runtime refuses it with a message.

### The obfuscated line and the 26.x line

Minecraft 26.1 and newer ship **unobfuscated** — official names are runtime names and there is no real
intermediary to remap through (26.1.2 publishes only the `0.0.0` placeholder). The fixer registration tables
address classes by name, so the two lines are not interchangeable: the obfuscated line registers intermediary
ids (`class_2586`), the 26.x line registers official paths
(`net/minecraft/world/level/block/entity/BlockEntity`). See `docs/LINES.md`.

## Testing

`test/launch.ps1` runs one release under a real launcher-equivalent classpath and `test/analyze.ps1` reads
the verdict; `tools/matrix.ps1` does both for one release and appends a row to the matrix report;
`tools/sweep.ps1` walks the whole list.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\sweep.ps1
```

Two harness details are not obvious and are recorded here because each cost a debugging round:

- The client is started through **WMI** (`Win32_Process.Create`). Every form in which the client stays a
  child of the harness — `cmd /c start`, a redirection, a pipe, even with the launch script detached — leaves
  the calling tool call open until its own timeout, long after the game reached the title screen. WMI gives
  the process no parent and no inherited handles.
- A profile cloned for a release that has no hand-made Fabric profile in `.minecraft/versions` must have the
  **older of its two ASM entries removed**. Fabric Loader treats a duplicate ASM on the classpath as fatal
  (`duplicate ASM classes found on classpath`), and Loader ships ASM itself.

`tools/FrameResolveTest.java` reproduces the frame-resolution logic offline against a cached class, which is
how the `getCommonSuperClass` bug fixed in 1.0.0 was found without launching the game.

## Logs and troubleshooting

| Log | Meaning |
|---|---|
| `[OptiLithium] Prepared N patched classes (S skipped, F failed)` | the pipeline result; `F` must be 0 |
| `[OptiLithium] ... created its X with A, while the game uses B` | a factory call was aligned with the game so a mixin's `@WrapOperation` finds it |
| `[OptiLithium] No common supertype for X and Y` | a recomputed frame degraded to `java/lang/Object`; a `VerifyError` is likely to follow |

`[OptiLithium]`'s output goes to the **launcher console**, not to `logs/latest.log`; filtering for
`[OptiLithium]` shows how many classes were prepared and which fixers fired.

Useful properties:

| Property | Effect |
|---|---|
| `-Doptilithium.mc-jar=<path>` | point the patcher at a specific vanilla client jar |
| `-Doptilithium.extract=true` | unpack the processed OptiFine classes under `.optilithium/<version>/classes` |
| `-Doptilithium.dumpFixed=<dir>` | write the final post-fixer bytecode of every class a fixer changed |
| `-Doptilithium.traceFrames=true` | print every class-hierarchy question the frame writer answers |
| `-Doptilithium.leaveConstructorTail=true` | keep OptiFine's constructor epilogue when restoring a supertype |

## License

**MPL-2.0** — see [`LICENSE.txt`](LICENSE.txt). The pipeline is a port of
[Chocohead/OptiFabric](https://github.com/Chocohead/OptiFabric) by Modmuss50 and Chocohead; ported files keep
their origin headers. OptiFine is **not** included or redistributed — it is sp614x's work, from
[optifine.net](https://optifine.net/). Lithium is **not** included either; it is CaffeineMC's work under
LGPL-3.0.

## Credits

- **[Chocohead/OptiFabric](https://github.com/Chocohead/OptiFabric)** — the original mechanism
- **sp614x** — OptiFine
- **CaffeineMC** — Lithium
- The **Fabric** team — Loader, Loom and tiny-remapper

---

**Note:** this is a community port. It is not affiliated with, endorsed by or supported by the OptiFine,
Lithium, Fabric or Mojang teams.
