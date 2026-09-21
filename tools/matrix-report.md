# OptiLithium version matrix

> **SUPERSEDED.** Every row below records a **title-screen** pass made on 2026-09-21, before the `BlockEntity`
> capability defect was fixed - and `tools/matrix.ps1` stops at the title screen, which is not the same as the
> mod working. The current, measured state of each release is in `tools/in-world-report.txt` and
> `docs/IN_WORLD_VERIFICATION.md`: 14 of the 16 supported releases load a world with a shader pack compiled.
> This file is kept only as the record of what the title-screen pass showed.

Produced by `tools/matrix.ps1` on 2026-09-21 with the jars built from this revision: build the jar for that release, launch a real client with OptiFine + Lithium, then read the log. "prepared / failed" is the pipeline's own line `Prepared N patched classes (S skipped, F failed)`; F must be 0.

| MC | verdict | prepared / failed | Lithium loaded | failure reason |
|---|---|---|---|---|
| 1.20 | FAILED | 410 / 0 failed | yes | Mixin transformation of net.minecraft.class_2586 failed | NoSuchMethodError |
| 1.20.1 | FAILED | 412 / 0 failed | yes | Mixin transformation of net.minecraft.class_2586 failed | NoSuchMethodError |
| 1.20.2 | FAILED | 423 / 0 failed | yes | Mixin transformation of net.minecraft.class_2586 failed | NoSuchMethodError |
| 1.20.4 | FAILED | 427 / 0 failed | yes | Mixin transformation of net.minecraft.class_2586 failed | NoSuchMethodError | Could not initialize class net.optifine.reflect.Reflector |
| 1.20.6 | FAILED | 426 / 0 failed | yes | Mixin transformation of net.minecraft.class_2586 failed | NoSuchMethodError | Could not initialize class net.optifine.reflect.Reflector |
| 1.21 | FAILED | 440 / 0 failed | yes | Mixin transformation of net.minecraft.class_2586 failed | NoSuchMethodError |
| 1.21.1 | FAILED | 425 / 0 failed | yes | Mixin transformation of net.minecraft.class_2586 failed | NoSuchMethodError | Could not initialize class net.optifine.reflect.Reflector |
| 1.21.3 | FAILED | 440 / 0 failed | yes | Mixin transformation of net.minecraft.class_2586 failed | NoSuchMethodError | Could not initialize class net.optifine.reflect.Reflector |
| 1.21.4 | FAILED | 474 / 0 failed | yes | Mixin transformation of net.minecraft.class_2586 failed | NoSuchMethodError | Could not initialize class net.optifine.reflect.Reflector |
| 1.21.6 | FAILED | 487 / 0 failed | yes | Mixin transformation of net.minecraft.class_2586 failed | NoSuchMethodError | Could not initialize class net.optifine.reflect.Reflector |
| 1.21.7 | FAILED | 500 / 0 failed | yes | Mixin transformation of net.minecraft.class_2586 failed | NoSuchMethodError | Could not initialize class net.optifine.reflect.Reflector |
| 1.21.8 | FAILED | 516 / 0 failed | yes | Mixin transformation of net.minecraft.class_2586 failed | NoSuchMethodError | Could not initialize class net.optifine.reflect.Reflector |
| 1.21.9 | FAILED | 519 / 0 failed | yes | Mixin transformation of net.minecraft.class_2586 failed | NoSuchMethodError | Could not initialize class net.optifine.reflect.Reflector |
| 1.21.10 | FAILED | 553 / 0 failed | yes | Mixin transformation of net.minecraft.class_2586 failed | NoSuchMethodError | Could not initialize class net.optifine.reflect.Reflector |
| 1.21.11 | FAILED | 570 / 0 failed | yes | Mixin transformation of net.minecraft.class_2586 failed | NoSuchMethodError | Could not initialize class net.optifine.reflect.Reflector |
| 26.1.2 | FAILED | 567 / 0 failed | yes | Mixin transformation of net.minecraft.world.level.block.entity.BlockEntity failed | NoSuchMethodError | Could not initialize class net.optifine.reflect.Reflector |
