# The `BlockEntity` conflict: what was tried, and what is left

This is the one problem standing between OptiLithium and every release. It is written down in full because
several plausible-looking fixes have already been tried and measured, and each one failed for a reason worth
not rediscovering.

## The conflict, stated exactly

OptiFine's patcher, on every release from 1.20 to 26.1.2, does two things to `BlockEntity`:

- sets its supertype to `net/minecraftforge/common/capabilities/CapabilityProvider$BlockEntities` (and adds the
  `IForgeBlockEntity` interface)
- rewrites the constructor's `super()` call to call that supertype's constructor

Lithium injects into that constructor with `ctor = true`, which makes Mixin look for a **delegate initialiser**.
It does not find one and throws `InjectionError: Delegate constructor lookup failed`, failing the whole class —
and because OptiFine's `Reflector` then cannot initialise, the client dies looking like OptiFine's fault.

## What Mixin actually requires (read from `sponge-mixin-0.17.4`)

`Injector.checkTargetForNode` throws when `Constructor.findDelegateInitNode()` reports
`DelegateInitialiser.isPresent == false`. That delegates to `Bytecode.findDelegateInit(MethodNode,
targetName, targetSuperName)`, whose rule, decompiled from the jar, is:

```
for each instruction:
    if (instruction is TypeInsnNode && opcode == NEW)          # 187
        newCount++
        continue
    if (instruction is MethodInsnNode && opcode == INVOKESPECIAL && name == "<init>")
        if (newCount > 0 && (owner == targetName || owner == targetSuperName))
            return present
return NONE
```

Two things follow, and both were confirmed by experiment:

1. the constructor being scanned must contain a **`NEW`** before the super() call;
2. the super() call's owner must equal the target class or `targetSuperName` **as Mixin's `ClassInfo` sees it**
   (`ClassInfo.getSuperName()`), not as the bytecode says it.

`BlockEntity` is abstract and its constructor contains no `NEW`, which is why 2 is the operative one.

## Experiments run, and their results

| # | Attempt | Result |
|---|---|---|
| 1 | **Skip the supertype repair entirely** (`-Doptilithium.skipSuperConstructorFix=net/minecraft/class_2586`) | **Identical failure.** The Forge supertype alone breaks the lookup, so neither this project's repair nor its absence is the cause. This rules out "the repair is the problem" for good. |
| 2 | **Add a synthetic delegate constructor** (`AddDelegateConstructorFix`): a private constructor with the same descriptor whose first instructions are `aload_0` + `invokespecial <forgeSuper>.<init>()`. | **No effect.** Mixin's rule needs a `NEW` before the constructor call, and there is none — see above. The fixer is deleted, not kept. |
| 3 | **Re-expose the orphaned members by delegating to the superclass** (`ReExposeInheritedMembersFix`): add `getCapabilities$optilithiumInherited` whose body is `invokespecial <forgeSuper>.getCapabilities()`. | **Fails verification.** `VerifyError` → `Could not initialize class net.optifine.reflect.Reflector`. `invokespecial` into a class that is no longer in the hierarchy is exactly what the verifier refuses. The class is kept in the tree, unregistered, with the reason in its header. |
| 4 | **Restore the supertype and the super() call together** (`RestoreSuperConstructorFix`) | **Works on 1.21.11** — the world loads and 54 shader programs compile — but orphans the capability members OptiFine's recompiled code calls, producing 132 `Failed to load data for block entity` errors per world load (NBT dropped). On 1.20–1.21.10 the class does not get out of Mixin at all. |

## Why 3 and 4 are two halves of one contradiction

- Keep the Forge supertype → the capability members resolve, but Mixin's delegate lookup fails (experiment 1).
- Remove it → Mixin is satisfied, but the capability members are orphaned (experiment 4), and they cannot be
  re-exposed by delegation because the verifier forbids `invokespecial` into a class outside the hierarchy
  (experiment 3).

There is no arrangement in which both hold while the supertype is the thing being changed.

## The precise reason no delegate can exist — and it is not what it first looked like

Two things were read out of `sponge-mixin-0.17.4`'s bytecode for this, and the first one corrects an earlier
guess in this file.

**First: this is not a supertype-name mismatch.** The 1.20.1 patched class does not extend what 26.1.2 does:

```
1.20.1:  class_2586 extends CapabilityProvider<class_2586> implements IForgeBlockEntity
26.1.2:  class_2586 extends CapabilityProvider$BlockEntities implements IForgeBlockEntity, class_12023
```

and on 1.20.1 its super() call is `invokespecial CapabilityProvider.<init>(Ljava/lang/Class;)V` — a different
owner *and* a different descriptor from the 26.1.2 shape. So an owner comparison against `targetSuperName`
never matched on that release, which is a version-specific difference and not the general cause.

**Second, and general: `newCount` can never be negative, so the condition is unsatisfiable by any constructor.**
`Bytecode.findDelegateInit` keeps a counter that goes **up on `NEW`** and **down on `invokespecial <init>`**,
and a candidate super call is only accepted when the counter is **already below zero**:

```
113: iload_3          # newCount
114: ifle 123         # if (newCount <= 0) goto candidate-check
117: iinc 3, -1       # else newCount--;        -> the call is an inner `new` being consumed
120: goto 163
123: ... candidate test: owner == targetName || owner == targetSuperName
```

The counter therefore tracks how many `NEW`s are in flight and *cancels out* each `new`'s constructor call. A
match needs a constructor call with **no pending `NEW`** — which is exactly what a `super()` call is — but the
counter only reaches that state after it has first been driven positive and then back to zero, i.e. after a
complete `new … <init>` pair has already appeared in the method **before** the super call. No constructor can
contain that: in every correctly compiled constructor the super() call is the first thing after the field
initialisers, before any `NEW`.

Which is why experiments 1 and 2 both changed nothing — neither could affect the counter — and why no edit to
`BlockEntity`'s constructor, supertype, or instruction order can make this lookup succeed.

**Nothing was left to test on this axis.** The only remaining directions are those that stop the lookup from
happening (the injection is not applied to this class), or that change where the scan is pointed — the latter
would mean influencing Mixin's own choice of target method, which this mod has no supported way to do.

## What is left to try

Ideas not yet ruled out, in the order worth attempting:

1. **Do not touch the supertype; satisfy `targetSuperName` instead.** The lookup compares against
   `ClassInfo.getSuperName()`. If Mixin's view of `BlockEntity`'s superclass can be made to agree with the
   Forge one — for instance by giving Mixin a reason to resolve it the way the bytecode says, or by making the
   class's supertype something Mixin reports identically — the delegate test passes with the class untouched,
   and the capability members are never orphaned. Nothing about this was tested; it is the most promising
   direction precisely because it leaves the runtime hierarchy alone.
2. **Provide the capability members without delegation.** A method on the class that returns a working
   `CapabilityDispatcher` instead of forwarding to the superclass would satisfy the verifier and keep
   `method_11014` working. Needs a way to obtain a dispatcher that does not go through the inaccessible
   supertype; on Fabric nothing appears to query one, so an inert instance may be enough — but that has to be
   measured, not assumed.
3. **Let the capability path not be reached at all**: rewrite `method_11014`'s call site so it does not ask for
   capabilities. This changes what OptiFine's own code does, which is the kind of thing this project has
   otherwise avoided.

## Downgrading the mod for these releases is not a way out

Renaming the mod id does **not** help. The id change is what gets past Lithium's
`"breaks": {"optifabric": "*"}`; with the id still named `optifabric`, Loader refuses to resolve the mod set
before any class loads. The `BlockEntity` mixin conflict happens later and independently of the id.
