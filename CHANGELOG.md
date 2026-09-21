# Changelog

All notable changes to OptiLithium. The format follows [Keep a Changelog](https://keepachangelog.com/) and
the version numbers are [SemVer](https://semver.org/) with the Minecraft release as build metadata —
`<version>+mc<release>`, one jar per release, both parts needed to identify a build.

The inherited history of the OptiFabric port this project is based on is in
[`docs/archive/`](docs/archive/); it documents the 1.20.6 → 1.21.11 pipeline work and is still the best
reference for how OptiFine's recompiler is repaired in general.

## [Unreleased]

### Fixed

- **Every release from 1.21.6 on crashed during game initialisation when a shader pack was selected.**
  OptiFine's patcher adds a `multiTex` field to the GL texture class along with `getMultiTexID()` /
  `setMultiTexID()`, and never initialises it. OptiFine's own shader code reads it through the virtual getter,
  which for a `DynamicTexture` resolves up the hierarchy to a stub returning null, and dereferences the result
  immediately: `NullPointerException: Cannot read field "norm" because "multiTex" is null`. The new
  `InitMultiTexIdFix` allocates the id on first use inside the class that owns the field, caching it by GL
  texture id, and every constructor calls the getter once after `super()` so the field is set as soon as a
  texture exists. `MultiTexID`'s constructor is read out of OptiFine's mapped jar because it changed shape:
  `(int,int,int)` through 1.21.7, three GL textures from 1.21.8.
- **That fixer was inert for a whole round.** It was registered under `GlTexture`'s Mojang path while the class
  being patched is named `class_10868`, and `RemappingUtils` returns a Mojang name unchanged, so the
  registration never matched - while the pipeline still printed `Prepared 487 patched classes (0 skipped, 0
  failed)` and the crash was identical. `registerFix` now registers both names.
- **A `getNext()` walk inside that fixer hung the client** at 100% of one core for eight minutes, with no
  crash, no error and `prepared=-`. Traversals go through `InsnList.toArray()`.
- **A class registered as an extra was patched twice when OptiFine also patched it**, a
  `ClassFormatError: Duplicate method name` on 1.21.9. `OptifineInjector` prepares the game classes first and
  skips an extra that already went through.
- **The id allocation used the texture's own GL id, which is 0 during construction**, producing
  `[Shaders] Error : MultiTexID.base mismatch: 0, texid: N`. It uses `GL11.glGenTextures()` for all three ids.

### Added

- `tools/build-all.ps1` builds every release and keeps one jar per release, because `build/libs` holds only the
  last one built and a sweep that alternates build and measure can otherwise test one release's jar against
  another release's game.
- `tools/world-launch.ps1` measures a release with a chosen mod set (`none` / `mine` / `of` / `all`), which is
  how the baselines for the defects above were taken.
- `tools/sweep-inworld.ps1` runs `tools/in-world.ps1` over a list of releases from one process.
- `tools/ClassInfo.java` and `tools/FindInCache.java` answer "what does this class declare" and "who references
  this" for an OptiFine class cache, which is how the `multiTex` mechanism was read out of bytecode.
- `-Doptilithium.traceFixes` and `-Doptilithium.traceClasses` report which classes a fixer reached and what it
  decided - the difference between "the fixer did nothing" and "the fixer never ran".

### Changed

- `tools/in-world.ps1` matches rig noise by prefix over the whole line. The old list matched only
  `Failed to load random sequence salt` while the sibling lines are `include_world_seed`, `sequences` and
  `include_sequence_id`, so a clean 1.20 run measured as `threadErrors=6 rigNoise=4`.
- `tools/in-world.ps1` refuses to run without its UTF-8 BOM. The default world name is Chinese; without the BOM
  PowerShell reads the script as ANSI and every release fails in four seconds claiming the world is missing.
- `launch.ps1` splits `-ExtraJvm` on commas and spaces. A caller through a shell hands a `[string[]]` over
  joined, so two properties arrived as one `-D` whose value was `true -Dsecond=...` - no property, no error.

## [1.0.0] — 2026-09-21

First release. OptiLithium loads OptiFine and Lithium in the same Fabric client, for Minecraft 1.20 through
1.21.11.

### Added

- **Its own mod id (`optilithium`), which is the point of the mod.** Lithium declares
  `"breaks": {"optifabric": "*"}` on every Fabric release, and Fabric Loader's solver matches that by id, so
  an OptiFabric jar can never be resolved next to it. No loader-side override can express this:
  `config/fabric_loader_dependencies.json` can only add, remove or replace a mod's *dependencies*, and a
  `breaks` entry naming a present mod is a hard conflict.
- **`RestoreSuperConstructorFix`**, and the conflict it exists for. OptiFine's patcher swaps `BlockEntity`'s
  supertype for Forge's `CapabilityProvider$BlockEntities` and rewrites the constructor's `super()` call to
  match. Lithium injects into that constructor with `ctor = true`, whose delegate-constructor lookup needs a
  `super()` call naming the class's real supertype, so Mixin failed the whole class — and with it OptiFine's
  `Reflector`, which is why the crash looked like an OptiFine bug. The fixer restores the supertype, the
  matching `super()` call and drops the Forge-only interface; both halves must move together, or the verifier
  answers `VerifyError: Bad <init> method call`. **The same conflict is the only thing that breaks 26.1.2**,
  so the fixer is shared and only its registration is per line.
- **A corrected class-hierarchy resolver** in the frame-computing writer. `getCommonSuperClass` returned
  `java/lang/Object` for the ordinary case "one class extends the other" (`class_278 + class_284`, where
  `class_284` extends `class_278`), because every supertype set contains `Object` and was tested by
  membership before equality. That is a frame the verifier rejects — measured as
  `VerifyError: Bad return type` in `class_5944.method_35785`. `tools/FrameResolveTest.java` reproduces it
  offline.
- Support for the whole obfuscated line: **1.20, 1.20.1, 1.20.2, 1.20.4, 1.20.6, 1.21.1, 1.21.3, 1.21.4,
  1.21.6, 1.21.7, 1.21.8, 1.21.9, 1.21.10 and 1.21.11**, each verified by launching a real client with both
  mods and reading the log (`tools/matrix-report.md`).
- **The 26.x line as well: Minecraft 26.1.2**, verified the same way. This is a project of its own (`:v26`)
  because 26.1 and newer ship unobfuscated — no Yarn mappings, no real intermediary, a different runtime
  namespace, a different Loom flavour and its own Java requirement. The pipeline is shared: `shared/` holds
  everything namespace independent and each line adds only its two mixins, its mixin config and its
  `fabric.mod.json`. That is possible because no fixer holds a compiled reference to a game class — every
  class name inside `patcher/fixes` is a string — so both fixer tables compile on both lines and the right one
  is chosen at runtime from the namespace. `docs/LINES.md` has the full comparison.
- A test rig (`test/`) that launches a release under a launcher-equivalent classpath and reports a verdict,
  and tooling (`tools/`) that builds a profile per release, runs one, and sweeps the whole list — now covering
  both lines, including the per-release Java level (17 / 21 / 25).
- `-Doptilithium.dumpFixed=<dir>` and `-Doptilithium.traceFrames=true`, without which the two failures above
  could not have been diagnosed: the class cache holds the state *before* the fixers, and the hierarchy
  resolver's answers are otherwise invisible.

### Changed

- The cache directory is `.optilithium/<OptiFine version>/`, not `.optifine/`. The cache is keyed only by
  the OptiFine version, so sharing the directory with OptiFabric would let the two mods hand each other
  class caches produced by different pipelines.
- `CrashReportMixin` selects its target **by descriptor**. It named `addDetails`, which is the 1.21 name;
  1.20 calls the same method `addStackTrace` (same intermediary id, same descriptor). A name in a mixin
  annotation is a *named-namespace* name, which Loom remaps for the release being built, so the 1.21
  spelling reached a 1.20 client and failed the whole mod with
  `Critical injection failure: … could not find any targets matching 'addDetails'`.
- One jar is built per release, and the build refuses a release whose Yarn mappings it does not have, rather
  than producing a jar that would remap OptiFine into nonsense.

### Known issues

- **1.21 is blocked by Lithium, not by OptiLithium.** Lithium's only build for the 1.21 family is made for
  1.21.1, and one of its mixins fails `net.minecraft.class_2614` (1.21's `HopperBlockEntity`, which OptiFine
  does not patch at all). OptiLithium + OptiFine alone reach the title screen on 1.21. Use 1.20.6 or 1.21.1.
- **1.20.3 and 1.20.5 have no OptiFine build.** The project builds jars for them, but OptiFine publishes
  nothing to put next to them; the same is true of 1.21.2 and 1.21.5.
