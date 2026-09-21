# Verification: what was actually measured

Two scripts, and the difference between them matters more than either result.

| | `tools/matrix.ps1` | `tools/in-world.ps1` |
|---|---|---|
| stops at | the title screen | a loaded world, with a shader pack |
| proves | the mod set resolved, the patch pipeline ran | chunk rebuild, block-entity construction, terrain and shader compilation |
| takes | ~3 minutes | ~2 minutes once the OptiFine cache exists |

**A title-screen pass is not a pass.** Everything this mod touches runs after a world loads, and the gap
between the two checks was the whole story here: at the title screen every release from 1.20 to 1.21.10 looked
identical to 1.21.11, and in a world all but two of them work.

## Result

Measured 2026-09-22 by `tools/in-world.ps1`, one release at a time, with the jars built from this revision.
The full table with counts lives in `tools/in-world-report.txt`.

| MC | world + shaders | what happens |
|---|---|---|
| 1.20 | yes, 54 programs | clean |
| 1.20.1 | yes, 54 programs | clean |
| 1.20.2 | yes, 54 programs | clean; a few OptiFine GL warnings (see below) |
| 1.20.4 | yes, 54 programs | clean |
| 1.20.6 | yes, 54 programs | clean |
| 1.21 | no | blocked by Lithium - `Mixin transformation of net.minecraft.class_2614 failed` |
| 1.21.1 | yes, 54 programs | clean |
| 1.21.3 | yes, 54 programs | clean |
| 1.21.4 | yes, 54 programs | clean |
| 1.21.6 | yes, 54 programs | clean; `OpenGL error: 1282 ... at: alphaTestRef` (see below) |
| 1.21.7 | yes, 54 programs | clean; same GL warnings |
| 1.21.8 | yes, 54 programs | clean |
| 1.21.9 | world yes, **shaders no** | `[Shaders] No shaderpack loaded.` - the one real gap |
| 1.21.10 | yes, 54 programs | clean |
| 1.21.11 | yes, 54 programs | clean |
| 26.1.2 | no | quick play opens no world - also true of vanilla 26.1.2 with no mods |

## The two defects that were fixed to get here

### 1. BlockEntity: dropped NBT for every saved block entity

Load a world on 1.21.11 and the log fills with:

```
[Server thread/ERROR]: Failed to load data for block entity net.minecraft.class_2591@... at position Block{minecraft:spawner}
java.lang.NoSuchMethodError: 'net.minecraftforge.common.capabilities.CapabilityDispatcher
  net.minecraft.class_2586.getCapabilities()'
  at net.minecraft.class_2586.method_11014(class_2586.java:123)
```

Each one is a saved block entity whose NBT was **dropped instead of loaded** — 264 of them in one session.

**Root cause.** `RestoreSuperConstructorFix` puts the game's own supertype back on `BlockEntity`, which is what
lets Lithium's `@Inject(ctor = true)` find its delegate constructor. That also removes everything the class
inherited from Forge's `CapabilityProvider$BlockEntities`, and OptiFine's own recompiled `method_11014` calls
`getCapabilities()` through `this`.

**The bridge approach does not work, and that is a JVM rule rather than an implementation detail.**
`ReExposeInheritedMembersFix` re-exposed those members with a body that delegates back to the removed
supertype. It ran, and it even removed the immediate symptom, but the class then failed verification:

```
VerifyError: Bad <init> method call
```

`invokespecial` into a class that is no longer in the class's hierarchy is exactly what the verifier refuses.
Preserving the runtime superclass while changing the declared one is not something a call site may do, so the
class is left in the tree unregistered, with that reasoning in its header.

**What works instead** is `NeutraliseCapabilityCallsFix`. The two call sites are null-guarded:

```
invokevirtual getCapabilities()LCapabilityDispatcher;
ifnull <skip>
```

so replacing the CALL with `aconst_null` makes the following `ifnull` take its branch and the
capability-dependent block becomes unreachable. That is the truthful outcome — on Fabric there is no capability
dispatcher, which is why the value is null on a Forge-less install with or without this mod. The instruction
count is unchanged, so every label, line number and branch offset stays valid.

### 2. GlTexture: the client died on its first dynamic texture

From 1.21.6 on, with a shader pack selected, the client died during game initialisation, before the title
screen:

```
java.lang.NullPointerException: Cannot read field "norm" because "multiTex" is null
  at net.optifine.shaders.ShadersTex.initDynamicTextureNS(ShadersTex.java:322)
  at net.minecraft.client.renderer.texture.DynamicTexture.method_71142(DynamicTexture.java:56)
```

OptiFine's patcher adds a `multiTex` field to the GL texture class along with `getMultiTexID()` /
`setMultiTexID()`, and **nothing ever initialises it**. OptiFine's own shader code reads it through the virtual
getter, which for a `DynamicTexture` resolves up the hierarchy to a stub returning null, and dereferences the
result immediately.

`InitMultiTexIdFix` allocates the id on first use inside the class that owns the field, caching it by GL
texture id, and every constructor calls the getter once after `super()` so the field is set as soon as a
texture exists. The `MultiTexID` constructor is read out of OptiFine's mapped jar because it changed shape:
`(int,int,int)` through 1.21.7, three GL textures from 1.21.8. Four other designs were measured and are recorded
in that file, including the two that look most reasonable — delegating to OptiFine's own static helper (which
recurses into the getter) and rewriting the helper to read the field (which dies on a `ClassCastException`,
because three of its four call sites are dispatched on a `DynamicTexture` and only the fourth holds a GL
texture).

## The two releases that do not reach a world

**1.21 is blocked by Lithium.** Its only 1.21-family build targets `mc1.21.1`, and its mixin fails
`net.minecraft.class_2614` — `HopperBlockEntity`, a class OptiFine does not patch at all (verified absent from
`.optilithium/<version>/Optifine.classes.gz`). There is nothing on this side to repair. OptiLithium + OptiFine
alone reach the title screen on 1.21.

**26.1.2 never opens a world, and neither does the game without this mod.** With a valid
`--quickPlaySingleplayer=<world>` pointing at an existing save, the client loads the shader pack, reaches the
title screen and stays there: no integrated server, no `Preparing spawn area`, no crash report. A thread dump
taken while it waits shows the render thread parked in
`Minecraft.renderFrame` -> `FramerateLimiter.limitDisplayFPS` — the ordinary game loop with nothing loaded. The
same command line on **vanilla Fabric 26.1.2 with no mods** behaves identically, and this mod's own contribution
to that run is `Prepared 567 patched classes (0 skipped, 0 failed)`, Lithium loaded, and no error of any kind.

## The one real gap: 1.21.9's shader pack

The world loads and the game runs with no crash and no error, but OptiFine reports
`[Shaders] No shaderpack loaded.` and compiles no programs, even though the pack is present in
`shaderpacks/`, selected in `optionsshaders.txt`, and visible to the module system. The 1.21.8 and 1.21.10
releases — on either side of it, and running the same OptiFine shader code — both load it. Recorded as a gap.

## GL warnings that are not failures

1.21.6, 1.21.7 and 1.20.2 log `[Shaders] OpenGL error: 1282 (Invalid operation), program: gbuffers_*, at:
alphaTestRef`. This is OptiFine's shader code talking to the driver about a uniform a modern GL core profile
does not have; the world loads, all 54 programs compile, and no data is dropped. Counted as thread errors
because that is what the log calls them, and listed here so the count is not read as a defect.

## Harness bugs found while measuring

Recorded because each one produced a false result before it was found:

1. **Stale logs.** `launch.ps1 -Fresh` cannot delete a game directory a running JVM holds handles inside
   (`.optilithium/`); `Remove-Item` failed, printed a warning, and the launch reused the previous run's logs.
   The reader then found `Preparing spawn area` in them and reported a world load for a run that never got past
   the title screen. Both scripts now stop the client, delete, **verify the delete**, and read only files
   written by the run in progress.
2. **Two log files read at once.** `rig-stdout.log` and `logs/latest.log` carry the same lines, so every count
   was doubled. Visible as `Setting user` x2 and `Program loaded` x54 for 27 programs.
3. **Reading markers before they are written.** Shader programs compile about 25 s after the world opens, so a
   reader that stops at `Preparing spawn area` reports `programs=0` for a run where shaders work.
4. **A noise filter that half-worked.** The rig-noise list matched only `Failed to load random sequence salt`
   while the sibling lines are `... include_world_seed`, `... sequences` and `... include_sequence_id`, so a
   clean 1.20 run measured as `threadErrors=6 rigNoise=4`. Noise is now matched by prefix, over the whole line.
5. **A script without its UTF-8 BOM.** `tools/in-world.ps1` uses a Chinese default world name; an edit that
   stripped the BOM made PowerShell read it as ANSI, and every release failed in four seconds claiming the world
   was missing. The script now refuses to run without the BOM.
6. **JVM properties that never arrived.** `-ExtraJvm '-Da=true','-Db=false'` reaches a child process joined into
   one element, so the JVM received a single `-D` whose value was `true -Db=false` — no property, no error, and
   a tracing switch that silently did nothing. Extra properties are split on commas and spaces now.
7. **A jar that was not the one being tested.** `build/libs` holds only the last release built, so a sweep that
   alternates build and measure can test one release's jar against another release's game. `tools/build-all.ps1`
   keeps one jar per release and `in-world.ps1` prefers it.
