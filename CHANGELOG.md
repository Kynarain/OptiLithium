# Changelog

All notable changes to OptiLithium. The format follows [Keep a Changelog](https://keepachangelog.com/) and
the version numbers are [SemVer](https://semver.org/) with the Minecraft release as build metadata —
`<version>+mc<release>`, one jar per release, both parts needed to identify a build.

The inherited history of the OptiFabric port this project is based on is in
[`docs/archive/`](docs/archive/); it documents the 1.20.6 → 1.21.11 pipeline work and is still the best
reference for how OptiFine's recompiler is repaired in general.

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
  answers `VerifyError: Bad <init> method call`.
- **A corrected class-hierarchy resolver** in the frame-computing writer. `getCommonSuperClass` returned
  `java/lang/Object` for the ordinary case "one class extends the other" (`class_278 + class_284`, where
  `class_284` extends `class_278`), because every supertype set contains `Object` and was tested by
  membership before equality. That is a frame the verifier rejects — measured as
  `VerifyError: Bad return type` in `class_5944.method_35785`. `tools/FrameResolveTest.java` reproduces it
  offline.
- Support for the whole obfuscated line: **1.20, 1.20.1, 1.20.2, 1.20.4, 1.20.6, 1.21.1, 1.21.3, 1.21.4,
  1.21.6, 1.21.7, 1.21.8, 1.21.9, 1.21.10 and 1.21.11**, each verified by launching a real client with both
  mods and reading the log (`tools/matrix-report.md`).
- A test rig (`test/`) that launches a release under a launcher-equivalent classpath and reports a verdict,
  and tooling (`tools/`) that builds a profile per release, runs one, and sweeps the whole list.
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
- **26.1.2 is not built here.** Minecraft 26.1 and newer ship unobfuscated, so there are no Yarn mappings and
  the fixer table must address the game by official path instead of intermediary id. `docs/LINES.md` records
  exactly what a second build flavour has to change.
- **1.20.3 and 1.20.5 have no OptiFine build.** The project builds jars for them, but OptiFine publishes
  nothing to put next to them; the same is true of 1.21.2 and 1.21.5.
