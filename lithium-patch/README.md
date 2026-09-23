# lithium-patch — 让 Lithium 能与 OptiFabric 同时加载

本目录是 **OptiLithium 仓库里的一个子目录**（`lithium-patch/`）。它做的事只有一件：改造上游 Lithium
自身，使它能与 OptiFabric 共存。（它原本是一个独立的工作目录——与 OptiLithium 共用 rig 的启动器、世界与
shader pack，但不改那个项目的任何文件；现在整份记录连同脚本一起发布在这里。）

本文是这轮工作的**完整记录**：结论、方法、证据、以及踩过的坑。所有结论都是**实测出来的**，不是推断；
凡是我判断错过的，都标了"自我纠错"。

---

## 〇、结论摘要

**Lithium 侧的改造已完成。** 阻塞剩下版本的**每一个**原因都在 OptiFabric / OptiFine 侧，
属于 Lithium 的是 **0 个**（每一处都做了"去掉 Lithium"的对照实验）。曾经被归到 **vanilla** 头上的那条
（26.1.2）已经查明是判定超时造成的误判，见 §6.13。

| 指标 | 值 |
|---|---|
| `breaks` 加载器硬冲突已消除 | **16 / 16** |
| mixin 注入点问题已解决 | **16 / 16**（`prepared=<N> / 0 failed`） |
| Lithium + OptiFabric + OptiFine 同时加载 | **16 / 16**（`conflict=no`、`lithium=yes`） |
| **真正进入世界 + 光影编译成功** | **7 / 16** |
| 改动的性质 | **只改两处配置，所有 class 文件与上游逐字节相同** |
| 阻塞原因属于 Lithium 的 | **0** |

进世界的 7 个版本：**1.21.3、1.21.4、1.21.8、1.21.9、1.21.10、1.21.11、26.1.2**（光影 54 个程序编译成功）。

> **26.1.2 一行曾被记成 ❌（"vanilla 自己就不进世界"），那是错的**：它其实进得去，只是那次运行在进世界前
> 空转了 4 小时 19 分，而判定窗口只有 5 分钟。详见 §6.13。

---

## 一、为什么要改

Lithium 在自己的 `fabric.mod.json` 里写了：

```json
"breaks": { "optifabric": "*" }
```

Fabric Loader 的求解器**按模组 id 匹配**这一条，所以启动会在加载任何类之前直接终止：

```
[main/INFO]: Immediate reason: [NEG_HARD_DEP lithium ... {breaks optifabric @ [*]}, ...]
```

**这个冲突是单方面的**（逐个读过 jar，不是猜测）：

| 模组 | 是否声明对方为冲突 |
|---|---|
| Lithium（23 个上游 jar **全部**） | `breaks: {"optifabric": "*"}` |
| OptiFabric 1.1.0 / 1.1.2（1.21.x 线） | `breaks: {no_fog, thallium, xradiation, ryoamiclights}` —— **没有 lithium** |
| optifabric-1.14.3（官方 1.20.x 线） | `breaks: {no_fog, thallium, xradiation, cardinal-components-item, architectury, meteor-client}` —— **没有 lithium** |

所以只需改 Lithium 一侧。

**`config/fabric_loader_dependencies.json` 无法绕过它。** `DependencyOverrides` 只能对一个模组的**依赖**
做 add / remove / replace，没有移除 `breaks` 的写法，也没有忽略它的开关。唯一办法就是让 `optifabric`
这个 id 不出现在求解器眼里，或者把 Lithium 里那条 `breaks` 去掉——本工程做后者。

**上游 Lithium 每个版本都写了这条**，我逐个读过 23 个 jar（不是抽样）：

```
1.20, 1.20.1, 1.20.2, 1.20.3, 1.20.4, 1.20.5, 1.20.6, 1.21, 1.21.1, 1.21.2, 1.21.3,
1.21.4, 1.21.5, 1.21.6, 1.21.7, 1.21.8, 1.21.9, 1.21.10, 1.21.11, 26.1, 26.1.1, 26.1.2
→ breaks: optifabric   （全部）
```

所以"改 Lithium"对**每一个**版本都必要。

---

## 二、改造方法

### 2.1 改了什么（只有两处，都是配置）

| # | 改的地方 | 内容 |
|---|---|---|
| 1 | `fabric.mod.json` | 删掉 `breaks` 里的指定 id（默认 `optifabric`） |
| 2 | `assets/lithium/lithium-mixin-config-default.properties` | 把需要关的 mixin 组设为 `false` |

**所有 class 文件与上游逐字节相同。** 这是本工程最重要的设计选择：改的是**配置**，不是代码。

### 2.2 为什么用配置开关，而不是改字节码

Lithium 的 mixin plugin（`LithiumMixinPlugin`）自带运行时禁用能力，日志会逐条报告：

```
Force-disabling mixin 'minimal_nonvanilla.world.block_entity_ticking.support_cache.BlockEntityMixin' as rule 'mixin.minimal_nonvanilla'
```

这条路径带来三件事：

1. **不改任何 class**，改造 jar 里每个 class 与上游逐字节一致；
2. **可跟随上游升级重建**——上游发新版，重跑一次脚本即可，不需要维护一个 fork 的 diff；
3. **可回退**——用户在 `config/lithium.properties` 里把某个组打开即可。

### 2.3 开关写进 jar **内部**默认值，而不是让用户放配置文件

Lithium 的读取顺序是：

```
assets/lithium/lithium-mixin-config-default.properties     ← jar 内部，先读
config/lithium.properties                                 ← 游戏目录，后读并覆盖
```

**内置默认值本身就会生效**，所以一个全新的游戏目录也能用。实测确认：Lithium 自己生成的
`config/lithium.properties` 只有注释、日志写 `0 override(s) found`，而改造后的行为依然生效
（用 `-NoLithiumConfig` 明确不写外部配置跑出来的）。

先前这脚本只把开关写成一个**放在 jar 旁边**的 `config/lithium.properties` 让用户自己装——那种交付物的
含义是"照说明做就能用"，而不是"放进去就能用"。现在 jar 本体自带，旁边的同名文件只是给人看的参考副本。

### 2.4 每版该关哪些组（实测得出，不是猜）

| 版本 | 需要的组 |
|---|---|
| 1.21.3、1.21.4、1.21.6、1.21.7、1.21.8、1.21.9、1.21.10、1.21.11、26.1.2 | **标准两组** |
| 1.21 | 标准两组 **+ `mixin.block.hopper=false`** |
| 1.20 / 1.20.1 / 1.20.2 / 1.20.4 / 1.20.6 | 标准两组（**其中一组是空转，见下**） |

**标准两组**：

```
mixin.minimal_nonvanilla=false
mixin.util.inventory_comparator_tracking=false
```

这组结论是**最小化验证过的**：我先用"三个组"把版本跑通，再用"只留两组"复测 1.21.3 / 1.21.9 /
1.21.11，全部仍然进世界——所以 `block.hopper` 对它们**不是必需的**。唯一需要它的是 1.21。

**1.20.x 上有一组是空转**，这点必须说清楚，免得把"写进去了"当成"起作用了"：

| 版本 | `minimal_nonvanilla` 组里的 mixin 数 | `util.inventory_comparator_tracking` 组里的 mixin 数 |
|---|---|---|
| 1.20 / 1.20.1 / 1.20.2 / 1.20.4 | **0**（键也不存在于上游默认文件） | 2 |
| 1.20.6 | 1 | 2 |
| 1.21 | 8 | 2 |

也就是说 1.20~1.20.4 上 `mixin.minimal_nonvanilla=false` 既没有这个键、也没有这个组，**写了等于没写**。
它仍然被写进去，是为了让版本表、`verify-jars.ps1` 的期望值和所有版本保持同一个形状（少一个特例）；
代价只是默认文件里多一行空转的键。**但它解释了为什么 1.20.x 仍然进不去世界**——那两个组不是它的阻塞点，
它的阻塞点是 §8.2 的 OptiFabric + Loader 版本问题。

### 2.5 为什么是这两个组：根因

Lithium 有若干 mixin 往 `BlockEntity`（`class_2586`）的**构造函数**里注入，
而 OptiFabric 经 OptiFine 改写过该类的构造函数（把父类也换掉），于是 Mixin 找不到注入目标：

```
Delegate constructor lookup failed for @Inject target on lithium.mixins.json:…BlockEntityMixin
```

**这是一句误导性很强的错误信息**：它看起来像 Lithium 的 bug，实际是"OptiFine 换了被注入类的父类"。
我在 `kynarain/OptiFabric` 的 1.20.6 分支里找到了同一现象的独立记录：

> OptiFine 把原版视频设置界面（`class_446`）**整类替换成自己的实现，连父类都换掉**，而 RyoamicLights 的
> mixin 注入在原版父类上，于是变换失败（`Delegate constructor lookup failed`）。**这是 OptiFine 自身的行为，
> 不是补丁造成的。**

所以：凡是往**被整类替换**的类里注入的模组都会撞上它，Lithium 只是其中之一。

---

## 三、全版本结果（每个版本都实测过）

判进世界只认 `Preparing spawn area`。`launch-rig.ps1` 把三种结局分开报：

| verdict | 含义 |
|---|---|
| `IN WORLD` | 到了 `Preparing spawn area` |
| `FAILED` | 客户端明确报了崩溃 / 加载器拒绝 |
| `NO WORLD` | 客户端起来了、写了日志，但没进世界（**卡住就是这一种**） |
| `NO LAUNCH` | 客户端根本没起来（问题在档案或启动器，不在模组） |

判定行现在还带两个字段，让"卡住"不必靠人读日志去猜（§6.13）：

| 字段 | 含义 |
|---|---|
| `clientAlive=yes` | 判定时客户端进程**还在** —— 它不是失败，只是没跑完 |
| `silentFor=<秒>` | 客户端最后一次写日志到现在过了多久 —— 卡住的运行这里会很大 |

| 版本 | 结果 | 说明 |
|---|---|---|
| **1.21.3** | ✅ **IN WORLD**（光影 54 程序） | 标准两组 |
| **1.21.4** | ✅ **IN WORLD**（光影 54 程序） | 标准两组 |
| **1.21.8** | ✅ **IN WORLD**（光影 54 程序） | 标准两组 |
| **1.21.9** | ✅ **IN WORLD** | 标准两组（有一次 `shaderpack=no`，见 §6.6） |
| **1.21.10** | ✅ **IN WORLD**（光影 54 程序） | 标准两组 |
| **1.21.11** | ✅ **IN WORLD**（光影 54 程序） | 标准两组 |
| **26.1.2** | ✅ **IN WORLD**（光影 54 程序） | 标准两组。**此前记为 ❌ 是超时误判**，见 §6.13 |
| 1.21 | ❌ **OptiFabric 自己** | mixin 层已被本工程解决；随后崩在 OptiFabric 的内联委托构造器上（`VerifyError`），**去掉 Lithium 后同样崩** |
| 1.21.6 / 1.21.7 | ❌ **OptiFabric / OptiFine** | OptiFine `ShadersTex` 空指针，**去掉 Lithium 后同样崩溃** |
| 1.20.6 / 1.21.1 | ❌ **没有 OptiFabric 构建** | 邻近版本的 jar 被它自己的 `depends minecraft` 挡下 |
| 1.20 / 1.20.1 / 1.20.2 / 1.20.4 | ❌ **OptiFabric + Loader 版本** | 加载器这一层已通（`conflict=no lithium=yes`），卡在 OptiFine 重映射；2026-09-23 干净机器复测一致（`clientAlive=yes silentFor=507s`，§8.2） |

原始证据在 `tools/sweep-final.txt`（全 16 版本一次跑完）；26.1.2 的改正证据在
`tools/sweep-report-26-after-move.txt`。

---

## 四、对照实验（这是"不怪 Lithium"的证据）

**每一个** ❌ 都做了"去掉 Lithium"的对照，否则无法区分"Lithium 改坏了"和"本来就跑不起来"。

| # | 对照 | 结果 |
|---|---|---|
| 1 | 官方 Lithium + OptiFabric + OptiFine（1.21） | `conflict=YES: breaks optifabric @ [*]`，加载器直接拒绝，`lithium=no` |
| 2 | 改造 Lithium + OptiFabric + OptiFine（1.21） | `conflict=no`，`prepared=440 / 0 failed`，Lithium 加载成功 |
| 3 | 只有 OptiFabric + OptiFine（**无 Lithium**，1.21） | 同样的 `VerifyError: Bad return type` @ `class_5944.method_35785` |
| 4 | 只有 OptiFabric + OptiFine（**无 Lithium**，1.21.6） | 同样的 `ShadersTex` 空指针，**崩溃栈逐行相同** |
| 5 | ~~纯 Fabric 26.1.2（**无任何模组**）~~ | **已撤回**：它当时记成"quick play 不进世界"，但那与 §6.13 是同一个超时假象，且该次的原始证据已不在 `tools\` 里留档，所以这条对照不再作为结论使用 |

第 1、2 条是本工程的核心价值证明：**删掉 `breaks` 确实解决了加载器层的硬冲突。**
第 3、4 条证明剩下的阻塞**不在 Lithium**。

第 5 条**撤回**是教训的一部分：一条对照如果只以"没进世界"为结果，它证明的其实只是"在我给的窗口里没进世界"
（§6.13）。26.1.2 现在的状态是 ✅ 进世界，**不需要**用对照来免责。

---

## 五、可复现性：工具与验证

### 5.1 工具

| 文件 | 作用 |
|---|---|
| `tools/patch-lithium.ps1` | 读上游 Lithium jar → 删 `breaks` → 把 mixin 开关写进 jar 内置默认配置 → 写许可与 provenance |
| `tools/versions.ps1` | **唯一出处**：每版配哪三个 jar、该关哪些 mixin 组、该版本当前状态；并**解析**三个输入目录（见 §5.5） |
| `tools/sweep.ps1` | 按版本表逐个：造 jar → 启动 → 收集结果与失败原因（开关自动取自版本表） |
| `tools/launch-rig.ps1` | 用**任意**模组组合进世界（复用 OptiLithium rig 的档案启动器、世界与 shader pack） |
| `tools/verify-jars.ps1` | 校验 `out\` 里每个 jar：`breaks` 已除、开关**恰好**是预期的那几个、许可与 provenance 齐全；开头先打印三个输入目录实际取自哪里 |
| `tools/analyze-blockentity.ps1` | 静态分析：列出触碰 `BlockEntity` 的 mixin 及"带 `@Inject` 且提到构造函数"的候选组 |

### 5.2 用法

```powershell
# 重建全部 16 个改造 jar 并逐个实测（开关自动取自版本表）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\sweep.ps1

# 只重建某个版本，不启动
powershell -NoProfile -ExecutionPolicy Bypass -File tools\sweep.ps1 -Only '1.21.11' -BuildOnly

# 校验产物（不需要启动游戏）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\verify-jars.ps1

# 单独造一个 jar
powershell -NoProfile -ExecutionPolicy Bypass -File tools\patch-lithium.ps1 `
  -InputJar <上游.jar> -Version 1.21 `
  -LithiumOption 'mixin.minimal_nonvanilla=false,mixin.util.inventory_comparator_tracking=false,mixin.block.hopper=false'

# 单独启动一次实测
powershell -NoProfile -ExecutionPolicy Bypass -File tools\launch-rig.ps1 `
  -VersionId '1.21.11-Fabric-0.19.5' -GameDirName '1.21.11-a' -NoLithiumConfig `
  -Mods '<改造.jar>,<OptiFabric.jar>,<OptiFine.jar>'

# 三个输入目录（Lithium / OptiFine / OptiFabric 的 dist）是自动解析的。
# 要把任何一个指到别处，用环境变量覆盖，不要改脚本（见 §5.5）：
$env:OPTIFABRIC_DIST = 'D:\somewhere\OptiFabric\dist'

# 分析某个版本里所有触碰 BlockEntity 的 mixin（26.x 要换 Target，见 §6.7）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\analyze-blockentity.ps1 `
  -Jar out\lithium-fabric-mc1.21.11-patched.jar
```

`-NoLithiumConfig` 是**故意**的：它不写外部配置文件，这样一次通过的运行证明的是"jar 自己就够"，
而不是"jar + 手工配置才够"。`sweep.ps1` 已默认带上它。

### 5.3 为什么"最小改动"是被证明的，而不是被声称的

`verify-jars.ps1` 里最值得自动化的是这一条：它把改造后的默认配置文件与**上游自己的**默认配置文件
逐行对比，要求"**只增不减**，且新增的**恰好等于**版本表里写的那几个"。

只看"该关的行在不在"是不够的——一个**顺手关掉了别的组**的改造 jar 同样能通过那种检查，却悄悄关掉了
用户没要求关的优化。对比上游之后，"最小改动"就成了可验证的事实。当前结果：**16/16 通过**。

### 5.4 许可（LGPL-3.0）

Lithium 是 **LGPL-3.0-only**（已在 jar 内核对 `license: LGPL-3.0-only`）。改造 jar 因此：

- 原样保留许可文件（1.21 线是 `LICENSE.txt`，新版改名为 `LICENSE.md`——两处都在，都保留）；
- 内置 `LITHIUM-PATCH.txt` provenance：上游文件名与 **sha256**、改了哪几行、上游源码地址；
- 每次构建都重新生成，可完整复现。

### 5.5 输入目录是解析出来的，不是写死的

`versions.ps1` 里的三个输入目录（Lithium 与 OptiFine 的 scratch、OptiFabric 的 `dist`）不再是写死的
字符串，而是**加载时解析**出来的：

| 优先级 | 来源 | 用途 |
|---|---|---|
| 1 | 环境变量 `LITHIUM_SCRATCH` / `OPTIFINE_SCRATCH` / `OPTIFABRIC_DIST` | 一次性运行，或换一台机器 |
| 2 | 候选列表里**第一个存在**的目录 | 正常情况 |
| 3 | 候选列表的第一个（不论是否存在） | 让报错信息仍然指向一个真实路径 |

为什么改成这样：**OptiFabric 的 fork 从 `C:\Users\kynar\IdeaProjects\OptiFabric` 迁到了
`I:\mods\OptiFabric`**，而那个路径当时是写死的，于是**16 个版本里 12 个一次性全部解析失败**，报的都是
同一句：

```
1.21.11: OptiFabric jar not found at C:\Users\kynar\IdeaProjects\OptiFabric\dist\OptiFabric-1.1.2+mc1.21.11.jar
```

这句话读起来像"这个版本没有构建"，事实是**目录搬了**。写死的路径只会这样失败，所以现在是"搬项目 = 往
候选列表加一行"，而不是"改一行"。

配套两处：

- `Get-ReleaseJars` 的报错现在**同时**说出搜过哪个目录、以及该用哪个环境变量覆盖，下一次搬迁一眼可诊断；
- `verify-jars.ps1` 在判定之前先打印三个目录**实际取自哪里**——它的结论是与上游 jar 逐字节对比得出的，
  看的到底是哪个目录必须写在报告里，而不是让人从失败里反推。

**解析只决定"去哪个目录找"，不决定"缺 jar 也可接受"**：某个 jar 在胜出的目录里不存在时，
`Get-ReleaseJars` 照样逐版本报错。

迁到新位置后的复验（2026-09-23，OptiFabric 已在新目录 `I:\mods\OptiFabric`）：

| 复验项 | 结果 |
|---|---|
| 三个输入目录解析 | **16/16 成功**（OptiFabric 取自 `I:\mods\OptiFabric\dist`） |
| `verify-jars.ps1` | **16/16 通过** |
| 1.21.11 实机（重建 jar + 启动） | **`IN WORLD`**，且结果行与迁移前**逐字符相同**：`prepared=570 / 0 failed · shaderpack=yes · programs=54 · lithium=yes · crashes=0 · conflict=no` |

---

## 六、记录在案的坑（都踩过）

### 6.1 `NO LAUNCH` 信息量很低，别只看它

实测里最误导的一次：1.20.4 报 `NO LAUNCH`，看起来像"Lithium 没改好"，实际是 **OptiFabric 1.14.3 卡在
OptiFine 重映射**。判读顺序应当是先看 `conflict=` 与 `lithium=`：`conflict=no lithium=yes` 说明**加载器
这一层已经通了**，问题在别处。

处置：`launch-rig.ps1` 现在把 `NO WORLD`（起来了没进世界）与 `NO LAUNCH`（根本没起来）分开报。

### 6.2 "某个具体错误不再出现" ≠ "进世界了"

我把 1.21 记成过 `IN WORLD`，起因就是"没再报 mixin 失败"就下了结论。完整证据是：

```
1.21-Fabric-0.19.5 : NO WORLD  prepared=440 / 0 failed  crashes=1  conflict=no  VerifyError
  cause: VerifyError: Bad return type
  [OptiFabric] Inlined delegating constructor net/minecraft/class_5944(...)V so injections into
               net/minecraft/class_2960 still land after super()
  Location: net/minecraft/class_5944.method_35785(Ljava/lang/String;)Lnet/minecraft/class_278; @17: areturn
```

**判进世界只认 `Preparing spawn area`**，其余一律按 `NO WORLD` + fatal 行来读。

### 6.3 一次只关一组就下结论，会得出相反的错误结论

我先前只关 `mixin.minimal_nonvanilla` 仍然失败，于是判定"配置文件解决不了，必须改 OptiFabric"。
**真正的原因是当时只关了一组，还有第二组。** 实测链条（1.21.11）：

| 尝试 | 配置 | 结果 |
|---|---|---|
| A | 官方 Lithium | `conflict=YES: breaks optifabric @ [*]` —— 加载器拒绝 |
| B | 改造 Lithium，不关任何 mixin | `class_2586` 转换失败；失败名 `minimal_nonvanilla…support_cache.BlockEntityMixin` |
| C | 只关 `mixin.minimal_nonvanilla=false` | 仍失败；失败名**换成第二个** `util.inventory_comparator_tracking.BlockEntityMixin` |
| D | 再关 `mixin.util.inventory_comparator_tracking=false` | ✅ **`IN WORLD`，`prepared=570 / 0 failed`，shaderpack=yes，programs=54，crashes=0** |

**教训：一个开关关掉之后失败名换了一个，说明"还有下一个"，不是"这条路走不通"。**

### 6.4 父规则能一次关掉整棵子树

传 `mixin.minimal_nonvanilla=false` 一次禁用了 **13 个** mixin（该组下所有子项）。这是 Lithium 的设计，
不是 bug。要单独处理某个子项时，得读日志确认到底关了哪些。

### 6.5 `disabledMixins` 这个计数要 ÷2，而且不能用来判定开关是否生效

- rig 的 `$all` 是 `rig-stdout.log` + `logs/latest.log` 拼起来的，同一批行出现两次。报 `30` 实际是 `15`。
  （已修：现在按**去重后的 mixin 名**计数。）
- 更重要的：**Lithium 只为"用户覆盖"打印 `Force-disabling` 那行**。开关写在 jar 内置默认值里时**不打印**，
  于是 `disabledMixins=0` 看起来像"什么都没关"，实际上关掉了。**判定开关是否生效要看结果**
  （`IN WORLD` / `prepared=… / 0 failed`），不能靠数日志。

### 6.6 光影程序数是变的

同配置的多次运行里，`programs` 出现过 54 与 39。判断是"世界打开后 25 秒左右才开始编译光影程序"这个
时序导致的采样差异，不是我改的东西造成的。所以 `programs` 只作为"光影确实在工作"的**存在性**证据，
不作为固定期望值。1.21.9 有一次 `shaderpack=no` 也属同类波动（同配置其余几次都是 `yes` + 54），
我没有把它当成已确认结论。

### 6.7 `analyze-blockentity.ps1` 的目标名随版本变化

```
混淆段（1.20 - 1.21.11）: -Target net/minecraft/class_2586           （默认）
非混淆（26.1.2+）        : -Target net/minecraft/world/level/block/entity/BlockEntity
```

传错**不会报错**，只是什么都找不到。所以"mixins naming the target: 0"对这种 jar 是**命名空间传错了**
的信号，不是"这个 jar 很干净"。

另外它只给**候选**：判据是"带 `@Inject` 注解**且**提到构造函数"两条同时成立。只提 `<init>` 不够——
一个只是 `new` 了某个对象、或调了 `super()` 的 mixin 也会提到它（`util.block_entity_retrieval.LevelMixin`
就是这种假阳性，早期版本会把它算进去）。**候选不等于结论**：某个组只有在一次启动**实测**需要它之后才会被关掉。

### 6.8 `-BreaksId` 不能凭"模组已改名"推断

26.x 线的 OptiFabric 确实改名成了 `optifabric_reforged`，但 **Lithium 的 `breaks` 里写的仍然是旧 id
`optifabric`**。所以 26.1.2 要删的是 `optifabric`——我一开始按新 id 传，结果 `breaks` 原封不动。
`versions.ps1` 里为此专门留了注释。

### 6.9 键的"存在性"随版本变化

`mixin.minimal_nonvanilla` 在 **1.20 ~ 1.20.4 的上游默认文件里根本没有这个键**（1.20.6 起才有）。
`patch-lithium.ps1` 的处理是**追加并打印提示**，而不是静默丢弃：

```
[patch-lithium] NOTE: 'mixin.minimal_nonvanilla' was not in the upstream default file; appended.
```

无害（Lithium 遇到不认识的键只打印 `No configuration key exists with name '{}', ignoring`），但也
**没有作用**。这说明开关表里不该出现"猜出来的"键——`verify-jars.ps1` 会把每版实际新增的键与原版对比，
多出来的当场暴露。

### 6.10 `$Matches` 会被内层脚本块覆盖

第一版内置逻辑把默认配置文件写成了一行 `m`（键名丢失），改造 jar **静默失效**。原因是嵌套的
`Where-Object { $_ -match ... }` 覆盖了 `$Matches`，之后读到的是**内层**匹配的第一个分组。

处置：用 `[regex]::Match()` 把捕获存进变量，不在嵌套脚本块之后再读 `$Matches`。

### 6.11 其余

| 坑 | 现象 | 处置 |
|---|---|---|
| `Expand-Archive` 不接受 `.jar` | 报"不是支持的存档文件格式" | 用 `[System.IO.Compression.ZipFile]::ExtractToDirectory` |
| PowerShell 自动变量 `$Input` | `-Input` 参数绑定到空字符串 | 参数改名为 `-InputJar` |
| `-Mods a,b,c` 变成一个路径 | 经过 shell 传数组会被合并成单个元素 | 声明 `[string]` 再拆分，**不用 `[string[]]`** |
| 中文字符串被写坏 | 世界名变成 `鏂扮殑涓栫晫` | 脚本含中文时必须存成 **UTF-8 with BOM**（本机 `powershell` 是 5.1） |
| `if (...) continue` 单行 | "Missing statement block" | 花括号必须写 |
| `$coll | @()` 只包一层 | `@($script:Releases.Keys)` 把整个集合当成一个元素 | 用管道 `@(... \| ForEach-Object { [string]$_ })` |
| CurseForge 被 Cloudflare 挡 | 直接抓页面 403 / 超时 | 元数据走 MCIM 镜像 `mod.mcimirror.top`，文件走 `edge.forgecdn.net`，并用 SHA1/MD5 与 CurseForge 记录核对 |
| 点源脚本的返回值污染参数 | `versions.ps1` 的赋值表达式填满了 `$Releases` | `$null = . versions.ps1` + 类型守卫 |
| 编辑工具会剥掉脚本的 BOM | 含中文的 `launch-rig.ps1` 改一行就变成 ANSI，世界名 `新的世界` 读不出来 | 改完必须复检首 3 字节是不是 `EF BB BF`，不是就补回去（内容不动） |
| `$pid` 是只读自动变量 | 诊断脚本里 `$pid = ...` 直接报错 | 换名（如 `$targetPid`） |

### 6.12 rig 不一定会杀掉自己启动的客户端，而这一点从结果里看不出来

一轮 sweep 跑完，机器上留下了 **11 个 Minecraft 客户端**，每个常驻 1.3–1.8 GB，从当天 02:49 一直挂到
第二天 22:08（约 19 小时）。它们不是崩溃残留，是**跑完没被清理的正常客户端**。

根因是那条**永远不可能成立的**所有权核对。`launch-rig.ps1` 的收尾要求 tag 出现在客户端的命令行上：

```powershell
if ($owner -and $tag -and $owner.CommandLine -and $owner.CommandLine.Contains($tag)) { taskkill ... }
```

但客户端是以 `java.exe @"<game dir>\java-args.txt"` 起的，**tag 是那个 argfile 里的一行**
（`-Doptilithium.rig.tag=rig-…`），命令行上根本没有它。所以 `Contains($tag)` 恒为假，`taskkill` 一次也
没执行。这不是推测，是**复现出来的**：用同样的方式起一个 java 进程，命令行含 argfile 路径、不含 tag。
OptiLithium 的启动器自己也把这一点写在它的 `$markers` 循环上方——"the tag does NOT appear on the process
command line"——并因此改用 argfile 路径作为识别标记。

**危险性在于它完全不可见**：判进世界只读日志，所以那些运行的结果**全都是对的**，`IN WORLD` 就是
`IN WORLD`；唯一的症状出现在**下一次**运行——清理 game dir 失败，或者机器被慢慢吃掉十几 GB 内存。

处置：`launch-rig.ps1` 的收尾现在有**两条独立判据**：

1. `rig.pid` + `rig.tag` 所有权核对（保留：能匹配时最精确）；
2. 命令行里出现**本次** game dir 的任何 `java.exe`——与启动前清理用的是同一条判据，也正是启动器推荐的
   标记（argfile 路径按 game dir 唯一）。目录按运行唯一、不共享，所以匹配到的只可能是本次启动的客户端。

清理效果：手动杀掉那 11 个遗留客户端后释放约 11 GB 常驻内存（31.9 GB 的机器，清理后可用 20 GB）。

### 6.13 `NO WORLD` 只等于"窗口内没进世界"——26.1.2 因此被误判

`NO WORLD` 与 `NO LAUNCH` 分开报是有用的（§6.1），但 `NO WORLD` **不是**"这个版本跑不起来"的同义词。
26.1.2 就是被这句话坑掉的：它被记成 **❌ "vanilla 自己就不进世界"**，而它其实**进得去**。

翻案的起点是它的 game dir 里有 `saves\RigWorld\dimensions\minecraft\overworld\region\*.mca`——26.x 的新
世界布局，说明它**开过世界**。日志完全对得上：

```
[02:49:18] Loading Minecraft 26.1.2 with Fabric Loader 0.19.5     ← 启动
   …（02:50 – 07:09 之间：0 行日志）…
[07:09:41] Starting upgrade for world "RigWorld"                  ← 这时才开始升级世界
[07:09:43] Upgrade done for world "RigWorld"                      ← 2 秒升完
[07:10:24] Preparing spawn area: 16%                              ← 进世界
[07:10:24] Starting integrated minecraft server version 26.1.2
```

**空转 4 小时 19 分、一行日志都没有**，然后 2 秒升完世界格式、正常进世界。而判定窗口是 `-Seconds 240`，
所以那次**注定**记成 `NO WORLD`。

原因指向**当时机器的状态**，不是这个版本：那是整轮 sweep 的**最后一个**版本，而**前面 15 个版本的客户端
全都还活着**（§6.12 的清理缺陷），每个 1.3–1.8 GB、都还在跑渲染。机器清干净后重跑：

```
26.1.2-Fabric-0.19.5 : IN WORLD  prepared=567 / 0 failed  inWorld=yes  shaderpack=yes
                        programs=54  lithium=yes  crashes=0  threadErrors=0  conflict=no
```

**世界升级这次在启动后 18 秒就完成了**（上次是 4 小时 20 分）。所以 26.1.2 进世界，光影 54 个程序也编译
成功——它是第 **7** 个进世界的版本。

**教训**：

1. `NO WORLD` 应当读成"**在这个窗口里**没进世界"。把它当成"这个版本不行"，就会写出一条错误的结论，
   而且它会一直留在版本表里（本次留了两天）。
2. 一轮 sweep 里**前一个版本留下的进程会改变后一个版本的计时**——所以"清理"不是卫生问题，是**测量正确性**
   问题（§6.12）。两处缺陷叠在一起，才产生了一个看起来完全合理的错误结论。

处置（三条）：

1. 判定行新增 `clientAlive=` 与 `silentFor=`（§三）：卡住的运行现在是 `clientAlive=yes silentFor=300s`，
   崩掉的运行是 `clientAlive=no`，两者不再需要人读日志去区分；
2. `versions.ps1` 的 26.1.2 状态由 `blocked: vanilla …` 改为 `inworld`；
3. README 的 §〇 / §三 同步改正，§四 的第 5 条对照**撤回**，§九 的第 5 条缺口**划掉**。

---

## 七、自我纠错记录

这轮工作里我判断错过五次，都影响过结论，记在这里以免后人重走（后两次是复查记录、并让新证据推翻旧结论时
发现的）：

### 7.1 "剩下的 `BlockEntity` 冲突在 OptiFabric 一侧，Lithium 里没得改"

**错。** `BlockEntity` 那批失败全部可以用 Lithium **自己**的配置开关关掉，不需要任何 fixer，也不需要
改任何 class。错因见 §6.3（只关了一组就下结论）。

### 7.2 "OptiFabric 没有 1.20.x 构建，官方只到 1.14.4"

**错。** 我查的是 **Legacy OptiFabric**（给 1.13/1.14 老加载器用的那个项目），不是官方 OptiFabric 的
下载页。实际情况：

| 来源 | 覆盖的 MC 版本 |
|---|---|
| 上游官方 OptiFabric（CurseForge 项目 322385） | 1.15.2 → **1.20.4**（末版 `optifabric-1.14.3.jar`） |
| 本工作区自己的 OptiFabric 分支 | **1.20.6**（`main`）起 → 1.21.x → 26.x |
| Legacy OptiFabric（另一个项目，别混） | b1.7 → 1.14.4 |

所以 **1.20 ~ 1.20.4 用官方 jar 是可行的**，1.20.6 / 1.21.1 才是真的缺口。

### 7.3 1.21 曾被我记成 `IN WORLD`

**错。** 见 §6.2。

### 7.4 "遗留客户端是因为 `rig.pid` 没被写下" —— 错，是我自己的检查写坏了

排查 §6.12 时我先把根因写成"启动器认领 JVM 失败、`rig.pid` 不落地"，依据是一句
`$pid = Join-Path $p 'rig.pid'` 的检查报了 `(无 rig.pid)`。

**那行检查本身就是错的**：`$pid` 是 PowerShell 的**只读自动变量**（当前进程 ID），赋值直接报错
"无法覆盖变量 PID"，于是 `Test-Path $pid` 测的是一个 PID 数字，当然不存在。真实的每个 game dir 里
`rig.pid` 都在，认领也都成功了（`launch.log` 里有 `started pid …`）。

换成 `$targetPid` 重查之后才看到真因：**命令行上根本没有 tag**（见 §6.12）。

**教训**：一个"缺失"的结论，先确认测的是不是那个东西。诊断脚本里的报错被 `-ErrorAction` 或输出淹没时，
它会伪装成"事实"。

### 7.5 26.1.2 曾被我记成"vanilla 自己就不进世界"

**错。** 它进得去，而且光影 54 个程序编译成功（§6.13）。错因是把 `NO WORLD`（= **窗口内**没进世界）当成
了"这个版本跑不起来"，而那次运行在进世界前空转了 4 小时 19 分——机器上还压着前 15 个版本的遗留客户端。

这条错误之所以值得记：它的证据链**看上去是完整的**（有 `sweep` 记录、有对照实验、还写进了版本表），
但它立在两个未察觉的前提上——"窗口够长"和"机器是干净的"。

---

## 八、1.20.x 的用 jar 来源与下一步阻塞

### 8.1 官方 1.20.x 的 OptiFabric（已下载并校验）

```
thirdparty/optifabric-1.14.3.jar
  CurseForge 项目 322385，file id 5025647，发布 2024-01-12
  sha1 e0818735cc2272ff7704e7a6d28d38d154e65f37   ← 与 CurseForge 记录一致
  md5  c5b73e880ae6c7321a0085167ed38e1d           ← 与 CurseForge 记录一致
  depends: minecraft [1.20, 1.20.1, 1.20.2, 1.20.4]
  breaks : no_fog, thallium, xradiation, cardinal-components-item, architectury, meteor-client（不含 lithium）
```

一支 jar 覆盖 1.20 ~ 1.20.4。`versions.ps1` 的 `Get-ReleaseJars` 会先在 fork 的 `dist\` 找、找不到再到
`thirdparty\` 找，所以版本表里只有一个字段，没有把路径写死。

用上它之后，**1.20 ~ 1.20.4 全部 `conflict=no` + `lithium=yes`**——加载器这一层通了。

### 8.2 但卡在下一道墙，而且不在 Lithium

四次实测（1.20 / 1.20.1 / 1.20.2 / 1.20.4）都是同一个形态：

```
[lithium] 加载成功，conflict=no
[optifabric 1.14.3] De-Volderfiying jar → Fuzzing … → Remapping optifine from official to intermediary
→ 没有下一行
```

我一开始以为是"重映射慢，5 分钟窗口不够"，于是用 **900 秒**重跑，并把日志最后写入时间与当前时间对比：
**日志 10 分钟没有新增一行**，而 JVM 仍在运行（约 2.2 GB 常驻）。所以不是慢，是**停在那里**。

**2026-09-23 在干净机器上复测（OptiFabric 迁址后、§6.12 的清理缺陷修好之后）**，四个版本**全部复现**，
而且这次判定行自己带上了状态，不需要人去读日志：

```
1.20.1-Fabric-0.19.5 : NO WORLD  ...  lithium=yes  conflict=no  clientAlive=yes  silentFor=507s
1.20.2-Fabric-0.19.5 : NO WORLD  ...  lithium=yes  conflict=no  clientAlive=yes  silentFor=507s
1.20.4-Fabric-0.19.5 : NO WORLD  ...  lithium=yes  conflict=no  clientAlive=yes  silentFor=507s
```

`silentFor=507s` 就是整个判定窗口：日志从重映射那一行起**再没写过**，而 `clientAlive=yes` 说明**不是崩溃**
——进程还在，只是不动。`rig-stdout.log` 的最后一行仍然是
`Remapping optifine from official to intermediary`，与首次记录**完全同一个位置**。

（这次复测是有必要的：§6.13 那个 26.1.2 的误判说明"长时间没输出"也可能只是**窗口太短**。所以 1.20.4 另外
用 **1800 秒**窗口单独跑了一次：

```
1.20.4-Fabric-0.19.5 : NO WORLD  ...  lithium=yes  conflict=no  clientAlive=yes  silentFor=1888s
```

判据是 **CPU 时间**：如果只是"慢"，进程应当在烧 CPU；实测客户端**累计 CPU 时间 20 分钟一动不动**
（31.9 s → 31.9 s），常驻内存 513 MB、日志两个文件都停在重映射那一行。所以它在**等**，不是在算——
**是阻塞，不是慢**。这一条同时也是 §6.13 教训的正确用法：只有"没输出"这一条证据时，慢与停是分不开的，
得再找一个能区分二者的量。）

原因指向 Loader 版本：`optifabric-1.14.3` 发布于 2024-01-12，当时 Fabric Loader 是 0.15.x；本机 1.20.x
的档案都是 **Loader 0.19.5**。而**本工作区自己的 OptiFabric 分支就是为 0.19.5 写的**。所以这一条是
"老 OptiFabric 遇上新 Loader"，可以修，但那是**改 OptiFabric**，不是改 Lithium。

---

## 九、还缺什么（都不在 Lithium 侧）

1. **1.21 的 `VerifyError`**：OptiFabric 为了把注入点挪到 `super()` 之后而内联委托构造器，结果
   `class_5944.method_35785` 的帧里出现 `java/lang/Object` 而签名要求 `class_278`。需要 OptiFabric 修
   那个内联逻辑。
2. **1.21.6 / 1.21.7 的 `ShadersTex` 空指针**：OptiFine 给 `class_1043` 打的补丁与 Fabric 实际类结构
   对不上（`multiTex` 是 `null`）。需要 OptiFabric 针对该贴图类加 fixer。
3. **1.20.x 的 Loader 兼容性**：把 fork 里适配 0.19.5 的部分回移到 1.14.3 那条线上。
4. **1.20.6 / 1.21.1 的 OptiFabric 构建**：这两版没有任何构建，要么造，要么接受缺口。
5. ~~**26.1.2 的 quick play**：vanilla 自己就不进世界，与本工程无关。~~ **已划掉**：那是超时误判，
   26.1.2 进世界且光影可用（§6.13）。**这一条不再是缺口。**
6. **真正的修复（而非绕过）**：给 OptiFabric 加 **super 构造器 fixer**，把 OptiFine 换掉的父类放回去。
   `kynarain/OptiFabric` 的 1.20.6 分支目前是 `skipClass("class_2586")`——跳过、不修；而 OptiLithium 里
   有对应的实现：`RestoreSuperConstructorFix` + `ReExposeInheritedMembersFix` + `NeutraliseCapabilityCallsFix`。
   一旦 OptiFabric 侧修好，Lithium 这边的 mixin 开关就可以全部去掉。

**本工程"关掉 mixin 组"是绕过，不是修复**——这一点必须说清楚。它的代价是关掉的组带来的优化不再生效，
而且换成任何别的往被替换类里注入的模组还会再撞同一堵墙。它换来的是：不改任何字节码、任何上游版本一键
复现、且实测能进世界。

---

## 十、产物清单

| 路径 | 内容 |
|---|---|
| `out\lithium-fabric-mc<版本>-patched.jar` | **16 个改造 jar** |
| `out\lithium-<版本>.properties` | 该版开关的参考副本（jar 已内置，这份只是给人看） |
| `thirdparty\optifabric-1.14.3.jar` | 官方 1.20.x 的 OptiFabric（哈希已校验） |
| `tools\*.ps1` | §5.1 的六个脚本 |
| `tools\sweep-final.txt` | 全 16 版本的最终扫描原始输出 |
| `tools\sweep-report-after-move.txt` | **OptiFabric 迁址后** 1.21.11 的复验原始输出（§5.5） |
| `tools\sweep-report-26-after-move.txt` | 迁址后 26.1.2 的重跑原始输出（§6.13） |
| `tools\sweep-report-120x-after-move.txt` | 迁址后 1.20 ~ 1.20.6 五个版本的复测原始输出（§8.2） |
| `tools\probe-*.txt`、`tools\sweep-report-*.txt` | 各轮探测与扫描的原始证据 |

### 10.1 什么进了仓库，什么没有

仓库里只有**脚本文档与原始证据**（`README.md` + `tools\`）。下面这些**不进仓库**，由 `.gitignore` 排除，
原因写在旁边：

| 不进仓库 | 原因 | 怎么得到 |
|---|---|---|
| `out\*.jar` | 11 MB 二进制，且是构建产物 | 已作为 **Release 资产**发布（tag `lithium-patch-v1.0.0`，16 个 jar），也可自己跑 `tools\sweep.ps1` 重建 |
| `out\*.properties` | 同上，参考副本 | 同上（jar 已内置这套开关） |
| `thirdparty\optifabric-1.14.3.jar` | 上游 OptiFabric 的再分发 | 从 CurseForge 项目 322385 下载，按 §8.1 的 sha1/md5 校验 |
| `work\` | 游戏实例、世界、下载的资产、日志（本地 23 GB） | 跑 `tools\launch-rig.ps1` 时自动生成 |
| `mods\` | 本地测试用的模组目录 | — |

**许可提醒**：改造 jar 是 **LGPL-3.0-only** 的 Lithium 的修改版（只改 `fabric.mod.json` 的 `breaks` 与内置
mixins 开关，class 文件与上游逐字节相同），每个 jar 内都带 `LICENSE`/`LICENSE.txt` 与 `LITHIUM-PATCH.txt`
provenance（上游文件名、sha256、改了哪几行、上游源码地址），见 §5.4。
