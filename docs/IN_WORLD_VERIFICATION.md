# In-world verification

The per-release matrix (`tools/matrix-report.md`) proves that the mod list resolves, the patch pipeline runs
and the client reaches the title screen. That is not the same as the mod working: everything this mod exists
for — chunk rebuild, block entity ticking, terrain rendering, shader compilation — happens **after** a world
is loaded. This file records the deeper run, on 1.21.11.

## What was run

| | |
|---|---|
| Minecraft | 1.21.11 (Fabric Loader 0.19.5, Java 21) |
| Mods | OptiLithium 1.0.0+mc1.21.11, `OptiFine_1.21.11_HD_U_J9.jar`, `lithium-fabric-0.21.4+mc1.21.11.jar`, `fabric-api-0.141.6+1.21.11.jar` |
| World | a real 1.21.11 world (`RigWorld`), loaded with `--quickPlaySingleplayer=RigWorld` |
| Shaders | `ComplementaryReimagined_r5.9.3.zip`, selected in `optionsshaders.txt` |

## What the log shows

| Check | Evidence |
|---|---|
| Mod set resolved with all four mods | `Loading N mods:` lists `optilithium`, `lithium`, `fabric-api`, `minecraft` |
| Pipeline ran clean | `Prepared 570 patched classes (0 skipped, 0 failed)` |
| **World actually loaded** | `Starting integrated minecraft server` **×2**, `Preparing spawn area` **×8** |
| **Shader pack loaded** | `[Shaders] Loaded shaderpack: ComplementaryReimagined_r5.9.3.zip` |
| **Shader programs compiled** | `Program loaded:` **×54** — `gbuffers_terrain`, `gbuffers_skybasic`, `gbuffers_clouds`, `shadow`, … |
| Framebuffers created | `Framebuffer` **×4** |
| No crash | no crash report written |
| No shader compile errors | no `Shader error`, `Failed to compile`, `GL_INVALID` or GLSL diagnostic in the log |
| No mixin/API conflict | no `Mixin apply failed`, `Critical injection failure`, `NoSuchMethodError`, `VerifyError` or `Incompatible mods` |
| OptiFine's subsystem up | `[Shaders] Load shaders configuration.`, `[OptiFine] [Shaders] Worlds: -1, 0, 1` |

Both `Starting integrated minecraft server` and `Setting user` appear twice because two log files are read for
the same run (`rig-stdout.log` and `logs/latest.log`), not because the world loaded twice.

## Why this run matters for this mod specifically

- **`Spawning area` / integrated server** means `LevelChunk` and `BlockEntity` construction ran for real. The
  `BlockEntity` constructor is precisely what `RestoreSuperConstructorFix` rewrites (see
  `docs/COMPAT_LITHIUM.md`), so a world that loads without crash is the direct evidence that the fixer's
  output is *correct*, not merely verifiable.
- **`gbuffers_terrain` loaded** means OptiFine's chunk-building path is live, which is the class
  (`SectionCompiler` / `ChunkBuilder`) several fixers exist to reconcile with Fabric's hooks.
- **Fabric API alongside the mod** is the combination the original OptiFabric warns about: Indigo's
  `ChunkBuilderBuiltChunkRebuildTaskMixin` targets a call OptiFine's rewrite of that loop removes, which is
  why this line declares `fabric-renderer-api-v1:contains_renderer` so Indigo steps aside. With Fabric API
  loaded here no mixin failure appeared — but note that this run also carries Lithium, and the combination is
  what was measured; Fabric API on its own was not separated out.

## What was NOT verified

Recorded so the claim is not read as broader than it is:

- **Other releases were only taken to the title screen.** Only 1.21.11 was taken into a world with shaders.
  A world from one release cannot be handed to another (data versions differ), so each release needs its own
  save; `tools/matrix.ps1` does not do that yet.
- **No screenshot was taken.** The evidence is the log, not a rendered frame.
- **No multiplayer run.**
- **Shader-pack warnings are expected and unrelated**: `Invalid block ID mapping: block.5000=` and friends are
  the pack naming blocks from another Minecraft version, and OptiFine prints them for any mismatch.
- **1.20.3 / 1.20.5 / 1.21.2 / 1.21.5 have no OptiFine build at all**, so they cannot be run in any form.

## Reproducing it

```powershell
# a world that release can open, in <game dir>\saves\<name>
# a shader pack in <game dir>\shaderpacks, named in optionsshaders.txt

powershell -NoProfile -ExecutionPolicy Bypass -Command "& { . '.\test\run-version.ps1' `
  -VersionId '1.21.11-Fabric 0.19.5' `
  -GameDir 'C:\Users\kynar\IdeaProjects\optilithium\test\run\w12111' `
  -Seconds 320 -Detach -QuickPlayWorld 'RigWorld' `
  -Mods '<optilithium jar>','<OptiFine jar>','<lithium jar>','<fabric-api jar>' }"
```

`-QuickPlayWorld` appends `--quickPlaySingleplayer=<name>`. The single-token `=` form is the one the client
parses; a space-separated pair is reported under "Completely ignored arguments" and the game then sits on the
title screen while the run still looks successful.
