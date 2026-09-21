# The two build lines

This project builds the **obfuscated** release line: Minecraft 1.20 through 1.21.11. The 26.x releases need a
second build flavour, and this file records exactly what differs, because the difference is not a version
number — it changes how every fixer addresses the game.

## Why the two cannot share one build

| | 1.20 – 1.21.11 | 26.1 and newer |
|---|---|---|
| Names at runtime | intermediary (`class_2586`, `method_11005`) | official (`net/minecraft/world/level/block/entity/BlockEntity`) |
| `mappings` dependency | `net.fabricmc:yarn:<release>:v2` | none — Yarn publishes nothing for 26.1.2 |
| `net.fabricmc:intermediary:<release>` | real mapping artifact | the empty `0.0.0` placeholder |
| Loom flavour | remapping (`fabric-loom`) | non-remapping (`net.fabricmc.fabric-loom`) |
| Runtime namespace | `intermediary` | `official` |
| Remap step in the pipeline | official → intermediary | skipped outright |
| Fixer registration table | intermediary ids: `registerFix("class_2586", …)` | official paths: `registerFix("net/minecraft/world/level/block/entity/BlockEntity", …)` |

`OptifineSetup` already handles the namespace difference at runtime: it asks
`FabricLoader.getMappingResolver().getCurrentRuntimeNamespace()` and skips the official→intermediary remap
when the answer is `official`, which is what it is on 26.1+ because `MappingConfiguration.hasAnyMappings()`
is false. The build and the fixer table are what do not carry over.

`registerFix` makes this concrete. Its key rule is: *if the string contains a `/`, use it verbatim;
otherwise prefix `net.minecraft.` and treat it as an intermediary id.* So on the obfuscated line a bare
`class_2586` is right, and on 26.x a bare name would be turned into `net.minecraft.BlockEntity`, which is not
a class. The 26.x table has to pass the whole path, and every judgement string inside every fixer — method
names, field names, descriptors — changes with it.

## The state of 26.1.2 here

`-Pmc=26.1.2` fails by design:

```
A problem occurred evaluating root project 'OptiLithium'.
> No yarn build is listed for Minecraft 26.1.2; add it to yarnBuilds in build.gradle
```

That guard exists because the alternative — letting the build proceed without mappings — would produce a jar
whose remapped OptiFine is nonsense, which fails much later and much less clearly.

Running it as a second flavour means:

1. a build path with no `mappings` dependency and Loom's non-remapping flavour (this is what OptiFabric's
   `26.x` branch does at its `build.gradle`);
2. a source tree, or a source set, whose fixer table registers official names — the two tables are not
   interchangeable, and `ClassFixer` itself is identical between them;
3. `OptifineInjector`'s `getCommonSuperClass`, which resolves the hierarchy from the launcher's own bytecode
   through `readGameClass`, keeps working unchanged: it maps from whatever namespace the game runs in.

The registration table from the 26.x line is the reference, and it lives in
`Kynarain/OptiFabric-Reforged` on the `26.x` branch, in
`src/main/java/kynarain/cn/optifabric/patcher/fixes/OptifineFixer.java`. Porting it is a rename of
registrations, not a redesign.

## What is already portable

Everything in `patcher/` that is not the registration table, plus:

- `OptifineSetup` — namespace detection and the skipped remap;
- `OptifineInjector` — the fixer driver, access widening, frame computation;
- `ClassCache`, `LambdaRebuilder`, `OptifineJarFixer`, `OptifineMappings`;
- the whole test rig in `test/`, which takes a profile id and needs no change at all.

The one thing to re-check on 26.x is the cache directory format: `.optilithium/<OptiFine version>/` is keyed
by the OptiFine version only, and `CACHE_FORMAT` has to be bumped whenever the produced bytecode changes, or
a warm cache is reused and the fixers never run.
