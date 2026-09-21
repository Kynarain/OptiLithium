# Making OptiFine and Lithium coexist

This is the record of what actually breaks when OptiFine's patcher and Lithium's mixins meet, how each break
was found, and what was done about it. Every entry below was reproduced in a real client; nothing here is
inferred from reading code.

The three things that stand between "put both jars in `mods/`" and a working client turned out to be of very
different kinds, and it is worth keeping them apart:

1. a **mod-id gate** in Fabric Loader that stops the launch before any class loads,
2. a **class-shape conflict**: OptiFine rewrites a class so that a Lithium mixin no longer has a target,
3. a **frame-computation bug** in this port, which is triggered by 2 but is not caused by Lithium.

## 1. The mod-id gate

**Symptom.** With OptiFabric and Lithium in `mods/`, nothing loads. The launcher stops with:

```
[main/WARN]: Mod resolution failed
[main/INFO]: Immediate reason: [NEG_HARD_DEP lithium 0.15.4+mc1.21.1 {breaks optifabric @ [*]},
                                  ROOT_FORCELOAD_SINGLE lithium 0.15.4+mc1.21.1,
                                  ROOT_FORCELOAD_SINGLE optifabric 1.1.0+mc1.21.1]
[main/ERROR]: Incompatible mods found!
```

**Cause.** Lithium's `fabric.mod.json` declares `"breaks": {"optifabric": "*"}` on every Fabric release
checked, from `lithium-fabric-mc1.20.1-0.11.4` through `lithium-fabric-0.24.7+mc26.1.2`. Loader's solver
matches that by **mod id**, so it does not matter that the id names a mechanism rather than a specific jar.

**What was tried first, and why it does not work.** Fabric Loader supports dependency overrides in
`config/fabric_loader_dependencies.json`, and the shape looks like exactly the right tool:

```json
{ "version": 1, "overrides": { "lithium": { "breaks": { "optifabric": "-" } } } }
```

It cannot express this. Disassembling `net.fabricmc.loader.impl.metadata.DependencyOverrides` out of
`fabric-loader-0.19.5.jar` shows the parser accepts only the root keys `version` and `overrides`, the
override keys are limited to the dependency kinds (`depends`, `recommends`, `suggests`, `conflicts`,
`breaks`), and only three operations exist: `Operation.ADD`, `Operation.REMOVE`, `Operation.REPLACE`. All
three operate on the mod's **dependencies** list. A `breaks` entry that names a mod which is present is a
hard conflict in the solver (`NEG_HARD_DEP`), and there is no property to ignore it —
`fabric.debug.disableModIds` disables a mod outright.

**Fix.** OptiLithium carries its own id:

```json
"id": "optilithium"
```

Loader compares ids, so a differently-named port of the same mechanism resolves next to Lithium without a
conflict. This is the whole reason the mod is named OptiLithium and not shipped as a patch to OptiFabric.
Confirmed live: the same run that produced the block above loads 6 mods once the id changes, and the log
shows both `lithium` and `optilithium` in the list.

## 2. `BlockEntity`'s constructor and its supertype

**Symptom.** With both mods loaded, the game dies before the window appears:

```
Caused by: org.spongepowered.asm.mixin.injection.throwables.InjectionError:
  Delegate constructor lookup failed for @Inject target on
  lithium.mixins.json:minimal_nonvanilla.world.block_entity_ticking.support_cache.BlockEntityMixin
  from mod lithium->@Inject::initSupportCache
  (Lnet/minecraft/class_2591;Lnet/minecraft/class_2338;Lnet/minecraft/class_2680;Lorg/spongepowered/asm/mixin/injection/callback/CallbackInfo;)V
    at org.spongepowered.asm.mixin.transformer.MixinTransformer.transformClass
Caused by: java.lang.RuntimeException: Mixin transformation of net.minecraft.class_2586 failed
Caused by: java.lang.NoClassDefFoundError: Could not initialize class net.optifine.reflect.Reflector
```

`class_2586` is `BlockEntity`; the mixin is Lithium's block-entity ticking support cache, and `Reflector` is
OptiFine's — so a single failed mixin takes OptiFine down with it and the crash looks like an OptiFine bug.

**The same conflict happens on the unobfuscated line, and there it is the only thing that breaks.** On 26.1.2
the names differ and nothing else does:

```
Caused by: java.lang.RuntimeException: Mixin transformation of net.minecraft.world.level.block.entity.BlockEntity failed
Caused by: InjectionError: Delegate constructor lookup failed for @Inject target on
  lithium.mixins.json:minimal_nonvanilla.world.block_entity_ticking.support_cache.BlockEntityMixin
  from mod lithium->@Inject::initSupportCache
  (Lnet/minecraft/world/level/block/entity/BlockEntityType;Lnet/minecraft/core/BlockPos;
   Lnet/minecraft/world/level/block/state/BlockState;Lorg/spongepowered/asm/mixin/injection/callback/CallbackInfo;)V
```

That is why `RestoreSuperConstructorFix` is in `shared/` and only its *registration* is per line: 26.1.2 is
green with OptiFine + Lithium precisely because of it (567 patched classes, 0 failed). It is also the reason
the last round of this port is small — with the fixer generalised, the 26.x line needed no new compatibility
work at all, only a second Gradle project and the official-name mixins.

**Cause.** Lithium injects into `BlockEntity`'s constructor with `ctor = true` and `@At("RETURN")`, a
*delegate constructor* injection. Mixin implements those by generating a synthetic constructor whose body is
`super()` plus a call to the handler, and it derives the per-constructor metadata from the real constructor —
which requires a constructor whose `super()` target is the class's own supertype. OptiFine's patcher replaces
both at once, for Forge compatibility:

| | vanilla 1.21.11 | OptiFine-patched |
|---|---|---|
| `super_class` | `java/lang/Object` | `net/minecraftforge/common/capabilities/CapabilityProvider$BlockEntities` |
| constructor `@1` | `invokespecial java/lang/Object.<init>()V` | `invokespecial CapabilityProvider$BlockEntities.<init>()V` |
| interfaces | `class_12023` | `IForgeBlockEntity`, `class_12023` |
| extra fields | — | `field_50172`, `nbtTag`, `nbtTagUpdateMs` |
| extra calls | — | `gatherCapabilities()` before `RETURN` |

Mixin's lookup then finds nothing to delegate to and fails the whole class.

**Fix.** `patcher/fixes/RestoreSuperConstructorFix`, registered for `class_2586`. It:

1. copies the vanilla constructor body,
2. restores `super_class` and drops the Forge-only interfaces OptiFine added,
3. drops OptiFine's constructor tail (the `gatherCapabilities()` call and the 21 instructions around it),
4. re-reads the result with `SKIP_FRAMES` and unknown `maxStack`/`maxLocals` so the frame-computing writer
   produces correct frames for the final class.

Three constraints had to be discovered by failing at them, and each is now a comment in the file:

- **The super call and the supertype must agree.** Restoring only the `super()` call while leaving
  `super_class` as Forge's gives `VerifyError: Bad <init> method call / Type 'java/lang/Object' is not
  assignable to 'net/minecraft/class_2586'`. The verifier requires a constructor's `invokespecial <init>` to
  target the class named in `super_class`, so both move together or neither does.
- **Splicing OptiFine's tail back in does not survive frame computation.**
  `NegativeArraySizeException: -1 at org.objectweb.asm.Frame.merge` — with the tail appended, ASM cannot
  compute frames for the method at all, even though the sequence is a plain `aload_0 / invokevirtual
  gatherCapabilities()V`. The tail is therefore dropped. What that costs is Forge's capability registration,
  which nothing on Fabric queries; the alternative is `BlockEntity` not loading. `-Doptilithium.
  leaveConstructorTail=true` keeps the splice for anyone who wants to revisit the trade.
- **`InsnList.toArray()` is unsafe while the list is modified.** It is ASM's only accessor of that kind and
  it hands back the caller's own backing array when it is large enough, so removing from the list while
  walking that array throws `ArrayIndexOutOfBoundsException`. This failed `class_2586` twice, silently - the
  fixer did nothing while the run still looked healthy. The file now walks with `getFirst()`/`getNext()` and
  says so.

## 3. The frame resolver, a bug in this port

**Symptom.** Once 2 was fixed on 1.21.11, 1.21.1 still died — but on a different class, and with no Lithium
involvement:

```
java.lang.VerifyError: Bad return type
  Location: net/minecraft/class_5944.method_35785(Ljava/lang/String;)Lnet/minecraft/class_278; @17: areturn
  Reason:   Type 'java/lang/Object' (current frame, stack[0]) is not assignable to 'net/minecraft/class_278'
```

`class_5944` is `ShaderProgram`. The method is byte-identical between vanilla and OptiFine's patch, and its
`StackMapTable` in the shipped bytecode is correct — so the wrong frame was **computed by this mod**.

**Cause.** When a fixer changes a class, the final serialisation recomputes frames through a `ClassWriter`
whose `getCommonSuperClass` resolves the game's hierarchy from the launcher's bytecode. That resolver had a
bug for the ordinary case "one class extends the other":

```
net/minecraft/class_278 + net/minecraft/class_284 -> java/lang/Object
```

`class_284` extends `class_278`, so the answer is `class_278`. Two orderings produce `Object` for that pair:

- walk `type2` up and return the first member of `supertypes(type1)`: every supertype set contains
  `java/lang/Object`, so the walk matches the moment it reaches `Object` — immediately, for any pair of
  plain classes;
- walk `type2` up but test membership before equality: the set holds `type2`'s *supertypes*, so the walk
  returns `type2`'s parent rather than `type2` itself whenever `type2` is the subtype — for
  `class_278 + class_284` that is again `class_278`'s absence from a set that does contain `Object`.

The working formulation tests the subtype case explicitly against sets that include each type itself, and
only then walks `type2` upward from `type2` itself. `tools/FrameResolveTest.java` reproduces it offline:
one pair check, then a full recomputation of `class_5944` that reports every hierarchy question asked.

**Fix.** `OptifineInjector.FrameComputingWriter.getCommonSuperClass`. On 1.21.1 the class then recomputes to
a correct frame and the client reaches the title screen with both mods.

**Why it went unnoticed.** It needs a class that is *both* changed by a fixer and contains a merge of a
supertype with its subtype. On 1.21.11 `class_5944` is not modified by any fixer, so its shipped frames are
kept and the bug is invisible; on 1.21.1 `VanillaFactoryCallFix` does modify it, frames get recomputed, and
the bug surfaces. The same latent bug is the documented cause of earlier `VerifyError`s attributed to
`class_983` on 1.21.8 and `class_898` on 1.21.3.

## What Lithium actually needed

One bytecode fixer, plus the id change. Everything else Lithium asks for survives OptiFine's patching
unharmed, which is worth stating plainly because the opposite is widely assumed:

- Lithium targets **intermediary names directly** and publishes **no refmap** (`lithium.mixins.json` has no
  `refmap` key and the jar contains no refmap file). Its targets therefore do not depend on how OptiFine's
  patched classes were remapped.
- It ships `"injectors": {"defaultRequire": 1}`, so a mixin whose injection point is missing **fails the
  whole class** rather than being skipped. Every such failure is fatal rather than a quiet loss of
  optimisation — which is why the only fix needed here had to be a real one.
- Lithium has its own `LithiumMixinConfigPlugin` and a config file with 150-171 options; the log line
  `Loaded configuration file for Lithium: N options available` is the cheap liveness check that it loaded at
  all.
