# Verification: what was actually measured

Two scripts, and the difference between them matters more than either result.

| | `tools/matrix.ps1` | `tools/in-world.ps1` |
|---|---|---|
| stops at | the title screen | a loaded world, with a shader pack |
| proves | the mod set resolved, the patch pipeline ran | chunk rebuild, block-entity construction, terrain and shader compilation |
| takes | ~3 minutes | ~6 minutes |

**A title-screen pass is not a pass.** Everything this mod touches runs after a world loads, and the gap
between the two checks turned out to be the whole story here.

## Result

| MC | title screen | world + shaders | what happens |
|---|---|---|---|
| 1.20 | ❌ | — | `Mixin transformation of net.minecraft.class_2586 failed` |
| 1.20.1 | ❌ | — | same |
| 1.20.2 | ❌ | — | same |
| 1.20.4 | ❌ | — | same, plus `Could not initialize class net.optifine.reflect.Reflector` |
| 1.20.6 | ❌ | — | same as 1.20.4 |
| 1.21 | ❌ | — | same as 1.20 |
| 1.21.1 | ❌ | — | same as 1.20.4 |
| 1.21.3 | ❌ | — | same as 1.20.4 |
| 1.21.4 | ❌ | — | same as 1.20.4 |
| 1.21.6 | ❌ | — | same as 1.20.4 |
| 1.21.7 | ❌ | — | same as 1.20.4 |
| 1.21.8 | ❌ | — | same as 1.20.4 |
| 1.21.9 | ❌ | — | same as 1.20.4 |
| 1.21.10 | ❌ | — | same as 1.20.4 |
| **1.21.11** | ✅ | ✅ **54 shader programs** | one defect, below |
| 26.1.2 | ✅ | not completed | reached the title screen; one world attempt stalled there and was not retried in the budget available |

## 1.21.11 is the only release that gets all the way, and it has a defect

Loaded a real world with OptiFine J9, Lithium 0.21.4, Fabric API 0.141.6, OptiLithium 1.0.0, and
`ComplementaryReimagined_r5.9.3` selected:

- `Prepared 570 patched classes (0 skipped, 0 failed)`
- `Starting integrated minecraft server`, `Preparing spawn area` ×3 — the world really opened
- `[Shaders] Loaded shaderpack: ComplementaryReimagined_r5.9.3.zip`
- `Program loaded:` **×54**, including `gbuffers_terrain` and `shadow`
- no crash report, no mixin failure, no shader compile error

**And then, on the same run, 132 `[Server thread/ERROR]` lines:**

```
[Server thread/ERROR]: Failed to load data for block entity net.minecraft.class_2591@... for block ... at position Block{minecraft:spawner}
java.lang.NoSuchMethodError: 'net.minecraftforge.common.capabilities.CapabilityDispatcher
  net.minecraft.class_2586.getCapabilities()'
  at net.minecraft.class_2586.method_11014(class_2586.java:123)
  at net.minecraft.class_2586.method_58690(class_2586.java:129)
  at net.minecraft.class_2586.method_11005(class_2586.java:257)   <- block entity creation
```

Each one is a saved block entity whose NBT was **dropped instead of loaded**. The game does not crash, which
is exactly why this survived a whole round of title-screen verification: the matrix had nothing to see.

### Root cause

`RestoreSuperConstructorFix` puts the game's own supertype back on `BlockEntity`. That removes everything the
class inherited from Forge's `CapabilityProvider$BlockEntities` — and OptiFine's own recompiled
`method_11014` calls one of those members, `getCapabilities()`, through `this`. With the supertype gone the
self-call resolves against the declared supertype (`java/lang/Object`), which has no such method.

The two requirements are in direct conflict. OptiFine's supertype must go, or Mixin's delegate-constructor
lookup fails for Lithium's `BlockEntityMixin` and the whole class — with OptiFine's `Reflector` — fails to
load. That is the failure the 11 red rows above show. But removing it orphans the capability members
OptiFine's own code still calls.

### The fix that was attempted, and why it is not here

`ReExposeInheritedMembersFix` re-exposes exactly those members on the class itself, with the bridge method
delegating back to the superclass:

```java
// getCapabilities$optilithiumInherited()Lnet/minecraftforge/common/capabilities/CapabilityDispatcher;
aload_0
invokespecial net/minecraftforge/common/capabilities/CapabilityProvider$BlockEntities.getCapabilities()...
areturn
```

It ran, and it fixed the immediate symptom — `NoSuchMethodError` gone from the log, `re-exposed 5 member(s)`
printed. Two rounds of bugs followed, both measured:

1. the scan read the supertype off `optifine.superName`, which the other fixer had already replaced, so it
   matched nothing and silently did nothing (fixed by passing the removed supertype in as an argument);
2. the rewrite then pointed the bridge's **own** call at the bridge, so it called itself:

   ```
   java.lang.StackOverflowError
     at net.minecraft.class_2586.getCapabilities$optilithiumInherited(class_2586.java)
     at net.minecraft.class_2586.getCapabilities$optilithiumInherited(class_2586.java)   ... x1000
   ```

3. after fixing that, the class no longer verified at all:

   ```
   VerifyError
   Could not initialize class net.optifine.reflect.Reflector
   ```

The last one is the wall. `invokespecial` into a class that is no longer in the class's hierarchy is exactly
what the verifier refuses (`VerifyError: Bad <init> method call` was the same wall earlier, from the opposite
direction). Preserving the runtime superclass while changing the declared one is **not** something the JVM's
verifier permits a call site to do, so the bridge approach cannot work as written.

The class is left in the tree, unregistered, with that reasoning in its header — so the next attempt starts
from what was learned rather than from the idea.

## What this means for the project's claim

- **15 of 16 releases do not work.** They fail at the title screen with the `BlockEntity` mixin error. The
  project's earlier "15 of 16 green" claim was measured with a reader that could pick markers out of stale
  logs; it was wrong.
- **1.21.11 works**, with shaders, and has a block-entity data-loading defect that loses NBT for saved block
  entities.
- **26.1.2 reaches the title screen.** Its world attempt stalls on the loading screen; not diagnosed.
- The `optilithium` **mod-id rename** — the one part that is not bytecode — is solid and verified: it is what
  gets the mod past Lithium's `"breaks": {"optifabric": "*"}` at all.

## Harness bugs found while measuring

Recorded because each one produced a false result before it was found:

1. **Stale logs.** `launch.ps1 -Fresh` cannot delete a game directory a running JVM holds handles inside
   (`.optilithium/`); `Remove-Item` failed, printed a warning, and the launch reused the previous run's logs.
   The reader then found `Preparing spawn area` in them and reported a world load for a run that never got
   past the title screen. Both scripts now stop the client, delete, verify the delete, and read only files
   written by the run in progress.
2. **Two log files read at once.** `rig-stdout.log` and `logs/latest.log` carry the same lines, so every
   count was doubled. Visible as `Setting user` ×2 and `Program loaded` ×54 for 27 programs.
3. **Reading markers before they are written.** Shader programs compile about 25 s after the world opens, so
   a reader that stops at `Preparing spawn area` reports `programs=0` for a run where shaders work.
