# OptiLithium version matrix

Produced by `tools/matrix.ps1` on 2026-09-21 with the jars built from this revision: build the jar for that release, launch a real client with OptiFine + Lithium, then read the log. "prepared / failed" is the pipeline's own line `Prepared N patched classes (S skipped, F failed)`; F must be 0.

| MC | verdict | prepared / failed | Lithium loaded | failure reason |
|---|---|---|---|---|
| 1.20 | TITLE SCREEN | 410 / 0 failed | yes | - |
| 1.20.1 | TITLE SCREEN | 412 / 0 failed | yes | - |
| 1.20.2 | TITLE SCREEN | 423 / 0 failed | yes | - |
| 1.20.4 | TITLE SCREEN | 427 / 0 failed | yes | - |
| 1.20.6 | TITLE SCREEN | 426 / 0 failed | yes | - |
| 1.21 | FAILED | 440 / 0 failed | yes | Mixin transformation of net.minecraft.class_2614 failed | Could not initialize class net.minecraft.class_2246 |
| 1.21.1 | TITLE SCREEN | 425 / 0 failed | yes | - |
| 1.21.3 | TITLE SCREEN | 440 / 0 failed | yes | - |
| 1.21.4 | TITLE SCREEN | 474 / 0 failed | yes | - |
| 1.21.6 | TITLE SCREEN | 487 / 0 failed | yes | - |
| 1.21.7 | TITLE SCREEN | 500 / 0 failed | yes | - |
| 1.21.8 | TITLE SCREEN | 516 / 0 failed | yes | - |
| 1.21.9 | TITLE SCREEN | 519 / 0 failed | yes | - |
| 1.21.10 | TITLE SCREEN | 553 / 0 failed | yes | - |
| 1.21.11 | TITLE SCREEN | 570 / 0 failed | yes | - |
| 26.1.2 | TITLE SCREEN | 567 / 0 failed | yes | - |
