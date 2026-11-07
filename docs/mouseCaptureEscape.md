# 瞄准捕获模式鼠标逸出：实现、验证与调查历史

**当前结论（2026-11-07）**：1823协议实现已进入正式构建链，Native/BG默认启用，保留各自显式0退出。相同OEM模块与1k鼠标条件下，窗口化、完整系统全屏、高速捕获不逸出、free跨窗、后台失焦不抢指针及返回游戏恢复均已完成物理验收；用户确认明显改善且无新问题，但未达到Windows原生手感。build29默认启动的实际映射与先前同源物理验收已核对，源码、完整哈希与验证方法见文末。当前重建入口为[原生兼容层构建脚本](../buildIdentityVNativeCameraCompat.command)，测试入口见[开发者指南](developerGuide.md#原生鼠标协议兼容层)。

## 2026-11-07早期隔离调查（历史阶段）

以下保留初始授权、未部署状态与失败路径；后续正式集成及实机结果以本文顶部和文末为准。

2026-11-07。用户报告按 `～` 进入瞄准捕获后，高速移动鼠标会逸出游戏窗口；明确要求保留自由模式跨窗口移动。本轮任务允许源码调查、日志白名单检索与独立候选，不允许启动游戏、发送输入、部署或修改 runtime manifest/catalog。历史的“单次捕获完全丢失”与本次“高速逸出”分开处理，不能自动视为同一故障。

**早期状态核验候选的实机结论：未修复高速逸出。** 用户在自定义模式完成低/高速对照，窗口化与系统全屏下高速均会逸出，方向无关、未切换 App，回到窗口又被拉到中心。主协调确认游戏实际加载已签名隔离诊断模块，但整个日志没有 v1 记录；0记录只说明观测链未到输出点，不能解释为修复成功、没有调用捕获或环境变量丢失。task-6 接续补齐诊断链路，见文末。之后v2已闭合观测链：主进程开关为1、nativeConfig为1，但完整自定义捕获复现中仍只有 reset/无限矩形、SetCapture/SetCursorPos，无有界driver clip或handler选择；预算未满。因此已排除“本轮开关丢失导致没记录”，仍须区分上层未请求与过滤。用户还确认后台露出的游戏区域会把指针拉回中心，要求后台任何模式都不抢指针；该问题与前台高速逸出分开处理。

## 已核对的运行条件

- 受管 runtime binding 指向 `wine11-codeweavers-26.1-dxmt-0.80-macos15-alpha1-r1-emoji2-audio-default-following-20261005-rc2`。
- 实际 `winemac.so` SHA-256 为 `365fefb1c0bf4c0e54f4fd3a00dbd44bd9a6febc75209846b6de2c270bdb9c60`，与 [分发清单](../runtimeBootstrap/runtime-manifest.json)一致。早期文档中的 `bd64b3…` 是签名前字节，不能据此判定安装了错误模块。
- runner 注册表契约使用 `UseConfinementCursorClipping=Y`、`CursorClippingLocksWindows=Y`。这证明预期配置；没有在本轮运行 Wine 查询活动注册表，也没有捕获故障瞬间的 handler/焦点状态。
- 11月现存 runner 日志的窄检索只发现注册表契约刷新记录，没有 ClipCursor 请求、native confinement 状态或逸出时序。默认 `WINEDEBUG=-all`，日志缺记录不能证明游戏没有调用捕获。
- 对应 CodeWeavers 26.1 源归档的 SHA-256 为 `e4ec87d5821a009dd1f1d2e36ffe2e24b8fcbae9516375ea42f95a16928ab8fa`；复用了已校验的既有归档，没有重新下载整套工具链。

## 两条实现路径与仍未知之处

`dlls/winemac.drv/mouse.c:macdrv_ClipCursor` 将有界矩形交给 `macdrv_clip_cursor`；既有 [reset 补丁](../wineMousePatch/eefbbc07-ClipCursor-reset.patch)将 reset/空请求转换为无限矩形，最终解除约束。它处理解除语义，不是高速逸出的已证实根因。

`cocoa_app.m:macdrv_clip_cursor` 先通过 `cgrect_mac_from_win` 做 Windows/Retina 坐标转换，再判断是否包含整个桌面；有界请求进入 handler，覆盖整个桌面/无限请求进入 stop。native handler 在 `cocoa_cursorclipping.m` 中先翻转屏幕坐标、与 owner window 的 frame 求交，再转为窗口内坐标，调用 `setMouseConfinementRect:`。因此这是矩形约束，不是把指针固定在中心点。该 API 的注释限定约束在 App 前台且窗口为 key/其 child 时有效，key 与 child 的区域取并集；窗口内部几何变化需要重设。Metal 视图渲染和 raw input 并不提供系统指针位置约束；本轮没有发现支持“DXMT 导致高速逸出”的动态证据。

另一条 `WineEventTapClipCursorHandler` 路径先用 `CGAssociateMouseAndMouseCursorPosition(false)` 分离指针和设备移动，再修改事件位置、手工 warp。它只对目标 PID 为当前进程的事件做 clip，对 Mission Control 等另进程事件刻意放行，并需要辅助功能权限。无证据切换该路径会改变权限和行为，不能作为低成本必然修复。当前 [Wine 上游实现](https://github.com/wine-mirror/wine/blob/master/dlls/winemac.drv/cocoa_cursorclipping.m)仍保留这两条路径及上述 native 限制；本轮未向上游发 issue。

尚缺：逸出时真实 ClipCursor 矩形、native readback、owner/key/frontmost 变化、系统全屏/显示器条件和相对事件时序。无法从静态源码确认高速时是 native 系统约束失效、游戏主动解除/重设，还是其他窗口/焦点路径。没有发送合成事件，因此没有“高速复现已通过”的证据。

## 窄候选：重复矩形必须核验 native 状态

[候选补丁](../wineMousePatch/confinement-state-validation.patch)修复一个独立可证明的缓存盲点：原控制器只要 `clippingCursor` 为真且屏幕矩形相同就直接成功，不再核对原生约束。这在 owner window 改变、几何投影变化或系统约束被清除后仍可能返回成功。

候选为 handler 增加可选 `isClippingCursorToRect:`：native handler 核对 owner window number、投影后的窗口矩形及 `mouseConfinementRect` 读回。只有这些都匹配时才复用缓存；其他情况执行原有 start，重新绑定约束。event-tap handler 保留原快退策略。新 start 在确认 owner/非空交集后才释放旧约束，避免失败请求无声地将现有捕获变成自由模式。

无限矩形/reset 的解除入口不变；没有键盘 hook、`～` 状态猜测、持续锁鼠、自动采样或全局默认路径切换。自由模式仍由游戏真实解除请求控制。该修复依赖后续捕获请求触发重新核验；若游戏不重发请求，它不会自动修复已经丢失的约束。native readback 一致也不能证明 WindowServer 在高速物理输入下确实约束了指针。

## 构建与验证

[构建配方](../wineMousePatch/buildCandidate.command)只接受精确源码归档与不存在的绝对输出目录，应用 reset 补丁及本候选，在独占目录配置并只构建 `dlls/winemac.drv/winemac.so`。它不安装/启动 Wine，不生成产品 manifest/catalog；新构建需先核对目标外盘的真实挂载身份与空间。调用者须提供 bison 3+ 的 PATH，不能依赖 macOS 自带旧 bison；若复用曾迁移的工具，还须以 `BISON_PKGDATADIR` 指向它实际的 `share/bison`，避免旧编译前缀下的数据目录缺失。命令示例：

```sh
PATH="/path/to/existing/bison/bin:$PATH" zsh wineMousePatch/buildCandidate.command \
  /path/to/crossover-sources-26.1.0.tar.gz \
  /path/to/Builds/IdentityV-Launcher/new-mouse-candidate
python3 wineMousePatch/testConfinementState.py \
  /path/to/Builds/IdentityV-Launcher/new-mouse-candidate/source
```

[状态合约测试](../wineMousePatch/testConfinementState.py)从实际已应用补丁源码提取 native handler 的实现，以内存窗口替身编译运行，不创建 NSApplication、原生窗口、Wine 或输入。14项检查通过：未捕获、有效读回、原生约束被清除后的失效/修复、几何变化失效/修复、owner 转移及旧 owner 清除、无 owner/无交集失败保留已有约束、新矩形失配、解除及重复解除。测试中的坐标投影采用恒等 flip，验证状态契约；它不验证真实屏幕翻转、WindowServer enforcement、Retina/多显示器或高速输入。

首次补丁 dry-run 发现手写 hunk 计数错误，已修正并重新 dry-run/应用通过。构建环境的失败路径：系统 bison 太旧；迁移后的既有 bison 虽为3.8.2，但内置旧数据目录不存在，须设置 `BISON_PKGDATADIR`；只设置 `CC=-arch x86_64` 会让 configure 仍将主机识别为 arm64，造成 Wine 头文件 ARM64/AMD64 类型冲突。配方现同时固定 build/host 为 `x86_64-apple-darwin` 和 C/C++ 编译器架构，避免混合身份。旧配方的 `SONAME_LIBVULKAN` 引号还会在 make 命令展开后丢失，导致连带构建的 `win32u` 将库名当标识符；配方已保留反斜杠引号，首次现场构建通过 make 的 CFLAGS 覆盖继续，并未修改 Wine 的 Vulkan 实现。一次续编链接未继承部署目标环境，初产物声明 minOS 27；已通过显式 `LDFLAGS=-mmacosx-version-min=14.0` 重新链接，并将该参数固化到配方，未用修改 Mach-O 版本号绕过编译。

最终候选构建成功：Mach-O x86_64，minOS 14.0 / SDK 27.0，SHA-256 `fed1f081c88e65b3565a0c47fff7b5b2671fd86b175d3895ce76eaaeca54ebfe`。`nm -gU` 的3个全局导出与现用模块完全一致；`otool -L` 的 install-name 与全部依赖身份/次序一致。该候选没有签名；代码签名检查报告 unsigned 是当前产物状态，不是签名验收通过。构建目录总计约356MiB，仅保留本任务源码、最小配置/辅助工具、模块与构建日志。现用模块的 SHA-256 仍为 `365fef…`。这些检查证明候选可编译及静态 ABI/依赖相容，不证明真实 Wine 加载、系统约束或游戏行为通过。

构建脚本 `zsh -n` 与14项状态测试通过；完整 App、签名/公证、runtime 分发材料/manifest、实际 loader 和游戏回归均未运行。这是 runtime 内部候选，不新增 GUI 业务操作或 Agent 命令。

## 最小后续验收

由主协调任务安排同一 runtime 的独立候选部署及用户操作时段，再对照原模块和候选：自由模式跨窗口、`～` 捕获下低速/高速移动、再次解除、切换焦点/返回、窗口模式/系统全屏与多屏边界。只记录捕获状态切换、窗口几何及限频异常，不录账号/输入内容，不新增后台采样。

候选不能替代动态根因验证，也不能以本地 App 编译成功冒称 runtime 已交付。以下 task-4 接续提供显式会话内的事件诊断，供主协调任务安排实机取证。

## 显式会话诊断候选（task-4）

以下是v1机制记录；v2的入口补齐、默认构建模式与共用预算见下一节。[诊断补丁](../wineMousePatch/confinement-session-diagnostics.patch)应用在状态核验补丁之后。状态/位置诊断默认关闭。仅对待取证的 Wine 启动进程显式设置：

```sh
IDENTITYV_CAPTURE_DIAGNOSTICS=1
```

该值须以环境变量传给真实 Wine 进程；其他值/未设置均关闭。不要写入用户全局环境、持久配置、manifest 或默认启动策略。输出到 Wine stderr，沿用本次启动入口的日志重定向；不需要开启包含按键/原始输入的 WINEDEBUG 通道。退出本次诊断游戏进程并在下次启动省略该变量即关闭；模块部署/签名与实际游戏启动仍由主协调任务安排。

机制没有 timer、后台线程、新 event tap 或输入发送。native handler 的 set/release/rebind-before 变化输出状态；既有 mouseMoved/drag/MouseExited 事件仅以事件自带的 CGEvent 屏幕坐标做缓存矩形检查，普通内界事件不查询系统指针位置，也不输出记录。发现越界时最多每秒读取一次同进程 owner window 的 native confinement、key/前台状态及当前系统指针；每个捕获 epoch 的每种异常最多输出一次。一个 handler 生命周期最多64条记录，达到上限后也停止异常快照；当前控制器只创建一个 handler。没有连续轨迹、按键、窗口标题、账号或聊天内容。若事件在逸出后不再送达 Wine，则本机制无法补采该次事件，日志缺失不代表没有逸出。

每行固定前缀 `IDV_CAPTURE_DIAG v=1`。字段：`pid/seq/epoch/uptime` 表示进程、记录序号、成功设置捕获的代次与单调时钟；`reason` 为 set/release/rebind-before/event-outside；`rect` 是捕获请求的 native 屏幕坐标矩形，`expected/native` 是 owner 窗口内投影与原生读回；`owner/frontOwner/key/active/eligible/frontPID/nativeMatch` 是窗口编号、App活动/窗口层级资格与前台进程归属。只有异常行额外包含 `event/current/currentOutside` 两个离散位置及当前越界布尔值：前者来自收到的事件，后者在诊断时从系统读取；不是连续轨迹。

| `kind` | 本行可支持的判断 |
| --- | --- |
| `transition` | 捕获设置/解除/重新绑定的状态快照，不包含指针位置 |
| `native-constraint-mismatch` | owner 不存在、投影为空或原生读回与预期失配 |
| `inactive-or-nonkey` | 原生读回匹配，但 App 非活动或 owner 不属于 key 窗口及其子窗口链 |
| `native-present-pointer-outside` | 原生读回匹配、App活动且窗口有资格，但当前系统指针仍在请求矩形外；可与约束丢失区分 |
| `event-outside-pointer-inside` | 收到的事件在矩形外，诊断时当前系统指针已回到矩形内；不能据旧事件判定当前仍逸出 |

原生读回、系统指针和前台状态不是 WindowServer 原子快照，临界时序仍可能发生变化；key/child 约束取并集、Mission Control 等系统行为也可能解释越界。因此 `native-present-pointer-outside` 是需结合现场判断的证据分类，不单独证明系统 API 或游戏存在缺陷。当前代码不自动恢复约束、不吞/改写事件、不将自由模式重新锁住。

验证：在原14项状态检查上，扩充实际 handler 提取测试，以内存窗口/指针/时钟替身验证默认关闭与精确开关、内界事件不读系统指针、四类异常、秒级门、epoch 去重、64条上限及达到上限后停止读回；多次越界调用没有修改约束。测试没有真实 NSApplication/窗口/输入。诊断模块增量编译成功，x86_64、minOS14.0，3个导出和全部依赖身份仍与现用模块一致。v1 首次交付产物 SHA-256 为 `8021c3e6c9abe189c8fd769682b1de7df767374a657395df1101da28c155ef79`；当时未签名/部署。之后主协调已对隔离副本签名并核实实际加载 SHA-256 `e668be5c9aa8b0e3990be6c92dbee801f0276aec81a6b239bcd221ed8d87100d`，用户真实测试仍复现且日志为0行，不能再将“未进行实机”作为当前状态。前一状态候选 `fed1f081…` 已单独保留；v1与后续v2各有稳定命名的独立模块，不能从构建目录默认文件名推断版本。

## task-6：零记录盲区与v2入口诊断

### 已排除与尚未确定

CodeWeavers26.1 的 `ntdll/unix/env.c:get_initial_environment` 会导入未知的 `IDENTITYV_*` 变量；特殊改名仅针对 PATH/HOME/TMP/XDG 等，忽略列表也不包含该变量。`ntdll/unix/process.c:write_env` 将整个 Unix environ 写给子 loader；`__CX_UNIX_` 是额外的 PE→Unix 变量提升机制，不是普通 shell 继承的前提。因此没有依据要求变量使用 WINE 前缀。`ps eww` 同时看不到已知 Wine 环境，也不能证明诊断变量丢失。本轮另以 lsof 核对真实游戏的 fd1/2 均指向取证日志，排除了“查错 stderr 文件”这一解释。

实际 prefix 的静态注册表仍为 `UseConfinementCursorClipping=Y`，未命中该键的 AppDefaults 覆盖或 GrabPointer 设置；静态文本不等于进程已经采用这些值。native handler 选择还取决于系统 selector 可用性；否则走 EventTap，v1不记录该路径。v1只有在 native start 成功后才输出：无 owner、空交集失败、没有有效 clip、EventTap 或开关关闭都会表现为0行。

`SetCapture` 在 mac driver 只改变鼠标事件所属窗口；`SetCursorPos` 独立 warp；二者都不必经过 `ClipCursor`。`win32u` 也可能在驱动前过滤请求，例如 GrabPointer 关闭或桌面范围 clip 被当作不约束。用户描述的“回来被拉回中心”与 warp 循环相容，当前只是待验证假设。驱动 marker 缺失不能证明游戏从未调用用户层 ClipCursor；首个 SetCursorPos 也可能来自 Wine 启动过程，不能单独归因到瞄准逻辑。

### 新模块与最小判读顺序

[入口诊断补丁](../wineMousePatch/confinement-session-entry-diagnostics.patch)应用在v1会话补丁后。新增共享 C transport，所有C入口 marker、handler状态与原有native快照共用进程级64条总预算和 once bits；写日志使用短互斥段并及时刷新 stderr，没有新线程、timer、hook、权限、游戏启动或事件改写。

仅隔离 `session` 构建带 `IDENTITYV_CAPTURE_DIAGNOSTIC_BUILD=1`：模块 load constructor 无条件发出一条 `reason=module-start`，只含进程/序号、`enabled=0|1`、诊断构建身份、`nativeConfig=-1`（此时尚未读Wine配置）与预算，不采输入、窗口或坐标。这样开关丢失也有明确证据。其余所有记录仍要求环境变量精确为1；普通构建没有无条件presence。状态候选完全不包含这条诊断链。

统一前缀为 `IDV_CAPTURE_DIAG v=2`。先确认以下链路，再安排用户进行一次捕获对照：

| marker | 用途与下一步 |
| --- | --- |
| `module-start enabled=0` | 模块确已加载，但原生 getenv 未读到精确1；先修启动环境，不要求用户盲测 |
| `module-start enabled=1` | 显式开关到达真实原生模块，仍未证明驱动初始化/捕获发生 |
| `driver-options nativeConfig=…` | 已通过 Wine driver 的 options 初始化；若只有presence而无此行，先定位初始化链路 |
| `driver-clip-request reset=… hasRect=…` | 分别对 reset/null/有矩形请求首次记录，证明请求到达 mac driver |
| `clip-dispatch bounded=… infinite=…` | 转换后请求是否真的需要约束；桌面范围/无限请求可能不创建 handler |
| `handler-choice nativeConfig=… apiAvailable=… selected=native|eventtap` | 明确配置、系统API可用性与实际选择，覆盖v1 EventTap盲区 |
| `native-start-failed cause=no-owner|empty-intersection`、`handler-start-failed` | 捕获失败出口，不能再用0行掩盖失败 |
| `driver-setcapture windowPresent=…` | 对设置/清除捕获归属各记录首次，不打印输入或坐标 |
| `driver-setcursorpos-first` | 原生warp路径至少发生过一次，不表示来自哪个游戏逻辑 |
| `mouse-event-no-clip handler=none|native|eventtap` | 既有首次move事件到达而 clippingCursor=false，只记录元数据 |

native成功设置后仍使用v1的四类异常与离散位置快照，但输出走共用v2 transport。事件/快照可以证明某条原生路径出现；不能从日志缺某类事件推断用户API调用不存在，也不能从marker出现推断高速故障已修复。预算达到64后停止输出，native异常快照也停止；应在判读时检查序号，避免将预算耗尽误判为未调用。

### 构建、测试与已验边界

[构建配方](../wineMousePatch/buildCandidate.command)第三参数现在为 `state-only|session`，默认 `state-only`：仅应用 reset/状态核验，不带诊断或presence。显式 `session` 才追加v1/v2诊断及编译宏。例：

```sh
PATH="/path/to/bison/bin:$PATH" BISON_PKGDATADIR=/path/to/bison/share/bison \
  zsh wineMousePatch/buildCandidate.command /path/to/crossover-sources-26.1.0.tar.gz \
  /path/to/Builds/IdentityV-Launcher/new-diagnostic-candidate session
python3 wineMousePatch/testDiagnosticTransport.py /path/to/candidate/source
python3 wineMousePatch/testConfinementState.py /path/to/candidate/source
python3 wineMousePatch/testDiagnosticModuleLoad.py /path/to/candidate/winemac.so /path/to/dependency-runtime
```

[transport合约测试](../wineMousePatch/testDiagnosticTransport.py)从实际C源码提取共享实现，验证普通/诊断构建×未设置/错误值/精确1六种组合，普通默认静默、隔离构建只有一条presence、module重复调用去重、C marker与普通snapshot共用64预算和连续序号。原14项状态及四类异常、秒级门、epoch去重与上限测试继续通过。

[真实模块加载探针](../wineMousePatch/testDiagnosticModuleLoad.py)编译短生命x86_64命令行程序，通过 `dlopen(RTLD_NOW)` 加载实际新模块与显式runtime依赖；不调用Wine/macdrv初始化、NSApplication、窗口或输入，也不attach活动游戏。环境变量缺失/精确1时，真实二进制分别输出且只输出一条 `module-start enabled=0|1`，验证了模块constructor的真实可达性；不是仅凭字符串或mock推断可用。

v2增量模块已构建：SHA-256 `01c3b71725f265cad6afbeb3bc2ceb0b7a48cad0c66d649ec6d6dc25cf26c244`，x86_64/minOS14.0，3个全局导出及全部依赖身份与正在测试的v1一致。未签名、未部署、未在游戏中加载；签名后哈希会变化，主协调须复核签后身份与真实加载。当前游戏/默认runtime/manifest/App未被本任务改动。v2随后已由Lead签名、部署到隔离runtime并真实加载；前台自定义高速仍逸出、free正常。整个日志15条，主进程8/64，开关/配置均为1，driver只有reset与无限clip，未出现有界请求或handler选择。该证据不能证明游戏从未调用用户层ClipCursor，下一层调查与v3交付如下。

## v3：上层过滤分类与独立后台warp保护

### 来源与最窄判断

`win32u/input.c:NtUserClipCursor` 仅拒绝反向矩形、做DPI映射，再将 set_cursor 请求交 wineserver。`server/queue.c:set_clip_rectangle` 与桌面范围求交并更新共享clip，将 `WM_WINE_CLIPCURSOR` 发往前台输入队列；处理消息时才进入 `process_wine_clipcursor`。该函数可能因 reset、GrabPointer关闭、矩形等于完整virtual screen或明确NOCLIP而解除/不下发有界clip。自动全屏clip另有窗口/前台/style/fullscreen、系统拖动与reset后1秒等条件；macOS系统全屏不保证满足其Windows全屏判断。v3不修改server或这些过滤规则。

v3上层仅记录 NtUserClipCursor 的 null/矩形 entry、非法矩形早退与server结果，以及 process_wine_clipcursor 的 reset/grab-disabled/desktop-equal/no-effective-clip/driver结果；自动fullscreen只记首次attempt，不扩全trace。若有 upper-clip-entry 但无后续process消息，应检查队列/前台派发；若有明确过滤cause，即可定位为何没有native有限clip。若上层entry也没有，只能说明该已加载win32u入口没有被观测到，仍不应把某个游戏UI状态直接等同API调用。

后台问题的独立缺口：NtUserSetCursorPos及server set_cursor没有原生macOS前台资格检查；Cocoa `setCursorPosition:` 只阻止拖动窗口，之后会直接warp并重新关联指针。`handleMouseMove:` 可以把后台露出Wine窗口下的移动交给游戏；resignActive发出异步释放消息，也不能禁止随后来的SetCursorPos。用户提供的后台中心拉回现象与此路径一致。

[后台warp资格补丁](../wineMousePatch/foreground-warp-eligibility.patch)保持独立可拆：在实际native warp/handler定位调用前，若App不活动或key window不是WineWindow，返回失败；没有改写返回值假称已移动，不重置移动事件队列，不自动启用clip，不用隐藏cursor/窗口进入猜捕获。拖动保护与合资格前台的free、native-clip、EventTap委托保持原路径。无key的启动期定位会被抑制；native start设置矩形后的附带定位也可能在后台被拒绝，这是避免后台动全局指针的预期边界。该层仅控制物理指针，未改win32u已提交的逻辑cursor状态；高层API原有返回/同步语义不被本补丁重新定义。

### 候选、预算与状态字段

[上层诊断叠层补丁](../wineMousePatch/upper-clip-session-diagnostics.patch)追加在v2之后。没有搬移transport或新增跨模块导出：macdrv固定48条，win32u固定16条，每层自己的static once/counter，故每个正常加载的一对模块/进程硬上限64条。日志前缀 `IDV_CAPTURE_DIAG v=3 layer=macdrv|win32u`，序号应按PID+layer分别判读。两个隔离模块在显式诊断构建中各有一条presence；其余记录仍须精确环境开关1。

`warp-focus-state` 在实际资格拒绝前记录现有缓存：active/Wine-key、mouseCaptureWindow存在、cursorHidden、clientWantsCursorHidden、dragging、denial与单调时钟。只在此前未见的状态组合记录；总预算仍封顶。cursorHidden是原生当前隐藏缓存，clientWantsCursorHidden是客户端请求缓存，mouseCaptureWindow表示事件归属，三者都不独立证明captured意图。代码没有用这些缓存启用任何约束。Lead另已反射确认本机NSWindow存在get/set confinement selector，这排除系统类完全缺方法，但仍不证明游戏选择了native handler。

### 保留原字体能力的构建边界

旧winemac最小配置为 `--without-freetype`；它产生的连带win32u不得用于替换原模块。本轮原win32u SHA-256 `15c047bb78a84da940eb86eff692e6aa6b74ed69975613c93715b9f3ce0f13f7`，动态后端为 `libfreetype.6.dylib` 与 `libMoltenVK.dylib`，有31个FT函数名。仓内emoji差异只修改gdi32/uniscribe与字体，没有本仓win32u补丁证据；基础预编译闭包来自原锁定上游，不能仅凭源码归档推断每个编译字节。v3复用同一CodeWeavers26.1归档及已有x86 FreeType headers/toolchain，开启FreeType、保持无fontconfig和原两个动态库名；只交付两个诊断模块，不替换FreeType库、gdi32 PE、字体、ntdll或其他DLL。

`buildCandidate.command` 保留 `state-only` 默认及原 `session`（v2）复建语义，另增 `paired`（v3诊断，无资格guard）与 `paired-gated`（v3诊断+独立guard）。配对模式要求显式 `IDENTITYV_FREETYPE_ROOT` 和 `IDENTITYV_BASE_RUNTIME`，使用FreeType开启配置，并自动运行[配对审计](../wineMousePatch/auditPairedModules.py)。普通两模式会明确提示其连带无FT win32u不是交付物。例：

```sh
IDENTITYV_FREETYPE_ROOT=/path/to/existing/x86-freetype \
IDENTITYV_BASE_RUNTIME=/path/to/verified/baseline-runtime \
BISON_PKGDATADIR=/path/to/bison/share/bison PATH="/path/to/bison/bin:$PATH" \
  zsh wineMousePatch/buildCandidate.command /path/to/crossover-sources-26.1.0.tar.gz \
  /path/to/new-build paired-gated
```

v2的patch、当时配方、真实模块加载测试、raw产物与改动前C/app/header/input已在独立Builds目录按SHA归档。两份状态/transport测试在归档指示前已被固定分额改动，归档清单明确标为修改后版本，不冒充原始v2字节快照；实际v2源码patch和raw01c3仍保留。v3采用新增叠层，不改写已实机的v2 patch。

### 验证与交接

- [过滤差分测试](../wineMousePatch/testUpperClipFilters.py)：编译实际修改前后函数，128个dispatch/filter组合与8个NtUserClipCursor entry组合的返回、server请求、逻辑clip计数与driver调用完全一致，新分类输出覆盖对应分支。
- [资格矩阵](../wineMousePatch/testForegroundWarpGate.py)：48个active/key/drag/captured/handler组合及native失败返回通过；被拒绝分支不warp、不改clip、不重置事件队列。测试不创建NSApplication/窗口或发送输入。
- 两层transport六种编译/环境组合、48+16预算、once/序号，以及原14项状态/四异常测试通过。实际x86_64 dlopen配对模块，环境缺失/为1时分别输出两层presence；没有调用Wine初始化或操作活动游戏。
- 原/新win32u完整505个导出、macdrv3个导出逐项一致；全部load依赖身份/次序一致，无新跨模块导出；原两个动态后端与31个FT函数名完全一致，且当前原FT库提供全部所需符号。两模块均x86_64/minOS14.0，原win32u为minOS10.15，未据此扩展系统承诺。emoji gdi32仍为 `0f608a883e86533cd6f79c007d40e43f017d13917d13a393f60b11a580e3051d`，与产品manifest一致。

当前交付是 `paired-gated`：winemac raw SHA-256 `abb9440758b31981a2a2c71d15f453fbbde8efe66f49ab964a3e0487298b7915`；win32u raw `c5f40e62e9cf341f5c7f016efc38b79f5e4537b7357ab3569cf7c0d83a04483f`。audit明确 `backgroundWarpGate=true`、`automaticClipEnabled=false`、预算48+16。未签名/部署，主协调须在进程退出后成对替换并核对签后哈希/实际加载；本任务没有操作游戏、GUI或默认runtime。静态导出/后端审计和dlopen不能代替真实字体显示、游戏内部API路径或后台/前台行为回归；前台focused+captured不逸出仍待上层证据支持的修复。

## v3真实回归：后台通过，转视角迟滞，不再重编主模块

用户确认v3后台失焦后不再抢指针，但前台高速仍逸出，同时新增明显转视角迟滞；静止画面流畅，尚未有FPS计数证明渲染帧率下跌。Lead先恢复原字节win32u（保留v3 mac/gate），迟滞仍在；再关闭事件诊断，同一mac/原upper仍迟滞。日志无刷屏、机器无热压/swap，不能把回归只归上层模块、日志I/O或全机资源不足。Lead随后恢复365 winemac与15c win32u原字节、env0且无compat做同场景基线，用户仍确认明显卡顿。因此重编、事件诊断与后台gate都不能单独解释全部迟滞，不能声称恢复OEM已解决性能。此前env0＋新mac/原upper的工具箱窗口约78.5秒，Metal均值37.41 FPS、最坏秒11 FPS、最大on-glass 467 ms、GPU均值5.63 ms；坏段早于唯一sample，且没有鼠标marker，不能据此确定HID因果。后续同一OEM会话、相近视角转速的触控板明显更流畅；只读确认鼠标配置为8000Hz、DPI原始字段5。Lead随后只写polling至1000并成功读回1000/DPI字段仍5，同一鼠标/会话中用户确认“明显改善、基本流畅”，明确要求保持1k、不恢复8k。没有DPI写入、恢复定时任务或本任务自行改设备。它是配置级单变量证据，不是测得8000次/秒实际Wine事件，也不证明全部卡顿根因；1k目前是保留的输入条件，前台缺少有效clip仍须独立修复。带外部紫色computer-use控制态的“free约1秒后自动回捕”单列污染：用户确认的是recapture随控制态变化，不能写成卡顿也随之消失；不把这些焦点/事件状态混入纯游戏结论。本任务不重复联合采集分析。

窄读结论：实际构建命令均为-g -O2，不是漏优化。原版与新win32u的NtUserSetCursorPos反汇编均先提交server，再仅在prev/new不同才调用driver，且忽略driver BOOL；GetCursorPos短期缓存逻辑位置，重复SetCursorPos又会刷新server时间，因此拒绝物理warp后存在逻辑/物理失同步风险。该风险可跨恢复upper保留，但在持续active+Wine-key时guard不拒绝，仍不能单凭源码将其定为前台迟滞根因。server有WM_MOUSEMOVE合并，不能把跳过native队列reset直接说成无限积压。once日志在命中后仍有getenv/短锁开销，不过env0后回归仍在，进一步削弱‘仅事件诊断’解释。全局强制包含sys/sysctl.h曾让configure函数原型探测误判为不可用；尚无证据将这些误判映射到此次迟滞，不继续盲调配置。

历史自建r5/r6/r8也曾在健康卷、O2下落后原r1；撤0006事件信号coalescing与换DXMT仅部分改善，未得到可直接复用的‘已完成高Hz修复’。本机原365与v3二进制都没有0006的event_signal_pending ivar和signalPostedEventAvailableLocked selector，均保留原signalEventAvailable。CodeWeavers原source的postEventObject本已有连续mouse move合并，v3未修改该文件。音频0004属于winecoreaudio，不属于winemac。因此本轮不把0006加回当修复，不声称pristine重编等价于原365性能；新SDK/编译器、Rosetta/shader cold或其他代码差异仍须以实证区分。capture adapter已暂停，先控制回归。

## OEM原字节后台保护compat候选（r2历史材料，禁止继续注入）

**r2及首个native组合的dlopen包装后来被真实启动证据推翻，不再是可部署候选。** 它们只通过了直接绝对路径加载的探针，未覆盖caller专有rpath及transitive加载；后续已完全移除loader interpose，见文末唯一runloop版。冻结材料保留作反证，不能再照旧方案拼接r2库。

为保留原365的全部事件/鼠标实现，新增独立[compat源码](../wineMousePatch/foreground_warp_compat.m)，不重编或替换winemac/win32u。它只包装WineApplicationController现有setCursorPosition:：原生App活动且key是WineWindow时，以保存的原IMP传入完全相同的self、SEL、CGPoint并原样返回原BOOL；不合资格返回NO，不调用原warp。不建立任何clip，不采样输入，不创建timer/thread/event tap，也不申请权限。

安装依赖必须实际验证，不能假定dyld add-image回调时ObjC类已注册。该候选透明包装dlopen，在原dlopen成功返回且目标basename为winemac.so后尝试安装；失败返回和errno保持原样，失败不运行安装器或消耗dlerror。安装器只接受方法所属模块SHA-256恰为原365、参数数目3、返回BOOL/参数CGPoint精确编码，并要求NSApp仍为nil，拒绝晚期附着。未知hash、签名或时机直接不安装，不触碰原IMP。此候选只能在启动显式注入，未用于活进程。

开关IDENTITYV_FOREGROUND_WARP_GATE必须精确为1，仅启动读取；默认无日志，可另设IDENTITYV_WARP_GATE_AUDIT=1输出一条install/skip见证，不记录事件。热路径没有getenv、日志或互斥锁，只读取现有NSApp资格并委派；仅链接libobjc/libSystem，不提前链接AppKit。该包装仍保留前述拒绝warp后的逻辑位置风险，24项委派fixture不能代替完整Winserver/游戏行为验证；它也不解决前台capture逸出。

[构建与无GUI验证脚本](../wineMousePatch/testForegroundWarpCompat.py)要求显式原runtime及不存在的新输出目录，先校验365/15c输入hash，构建x86_64/minOS14.0独立dylib，再在新的CLI进程验证：

- 实际加载原365后，selector编码为c32@0:8{CGPoint=dd}16，NSApp仍nil；启动开关1安装成功，开关0或无shim保持原方法。
- 原dlopen完成后的安装时机由实际模块探针证明，未创建NSApplication、窗口、prefix或输入；对成功/失败errno与失败dlerror做无shim/disabled/enabled对照，结果相同。
- 24个资格/返回/坐标组合保留原self、SEL、双精度CGPoint及BOOL，包括原实现返回NO；hash/type检查拒绝不匹配。
- 另实际加载未知hash的v3模块，安装器输出baseline-identity拒绝，IMP仍属于原模块；不是只测试hash辅助函数。

```sh
python3 wineMousePatch/testForegroundWarpCompat.py \
  /path/to/verified-original-runtime /path/to/new-compat-output
```

当前raw compat SHA-256 `981fa073f721db19169619fc818de886f22bab6e77a3ef68687e5aac6db71350`，源码SHA-256 `24482a45c65e17403aaecd1a63167afb80598ab38eace7f38648d38cf0f6172a`；未签名/部署。真实输入模块365/15c在探针前后字节不变。Lead须等待OEM前台性能基线，并在后续隔离启动中按既有DYLD_INSERT_LIBRARIES拼接方式选择性加载，不覆盖已有兼容层；不会自动改默认runtime、启动器或日用配置。若系统丢弃注入、类/NSApp时序不同，必须据install见证判为未安装，而非把映射成功当保护生效。

## OEM组合候选：严格联合信号与native-only lease（737历史资格已被反证）

本节起始方案及唯一runloop产物737已实际启动，但把Win32 SetCapture当camera必要条件的部分被后续会话推翻。最新源码修补与性能调查见文末；737不能再作为前台高速已修或下一默认注入候选。

性能对照已有1k改善结果，前台captured不逸出的目标继续，不停在后台compat交付。新增[组合候选](../wineMousePatch/native_camera_compat.m)与[验证脚本](../wineMousePatch/testNativeCameraCompat.py)，复用冻结的foreground源码，仅包装OEM原方法，不重编Wine模块。只在显式IDENTITYV_NATIVE_CAMERA_CLIP=1、getprogname为dwrg.exe、目标仍为已知365 hash/type时启用native；最终runloop版在主线程、原事件sources处理前安装，可接受已创建但无key窗口的NSApp，已有key窗口则fail-transparent拒绝晚期安装。Wine ntdll的set_process_name按PE basename设置进程名，原OEM ntdll确实导入setprogname；实际会话仍须用installed见证确认安装，没有见证就按未安装处理。

进入条件全部成立才申请lease：App active；key是WineWindow；客户端确实请求隐藏；mouseCaptureWindow是该key或同parentWindow root且本身是WineWindow；没有窗口拖动；现有warp目标经原flippedMouseLocation转换后位于原生内容区中心±1 native point；Windows原clippingCursor为false。先调用保存的OEM定位IMP并原样返回结果，只有原定位成功且焦点未变、native confinement原为空时才写约束，立即核对readback。失败不伪造已定位、不转EventTap，readback失败最多尝试一次，须模式/owner/geometry等失效后才允许重新尝试。

坐标严格取原NSWindow frame→contentRectForFrameRect→convertRectFromScreen，保留原生点单位/负屏幕坐标，不把Retina像素再乘一次。几何缓存只在owner变化或原Cocoa move/resize/screen/close通知时失效，不逐事件读取整套frame。该原生内容区可能与Wine真正Win32 client_view存在非客户区偏移；如果已知camera时centerTarget为0，应判为具体几何/意图冲突，不放宽阈值或改成hidden单条件捕获。同样，若camera持续无ownedCapture，须带回冲突，不能自行删除该前提。

它直接复用NSWindow已有confinement getter/setter，只设完整原生内容区域，不构造EventTap handler，不创建timer、输入tap或新权限。独立标记自身owner/capture/readback；unhide、capture释放/owner变化、非中心warp、失焦/key切换、窗口关闭/移动/缩放/换屏、App退出通知都撤销自己的lease。撤销时仅当native当前rect仍等于本lease readback才清空；外部已经改变则只丢弃本方所有权。原Windows startClippingCursor先撤自己再原样委派，让其显式clip优先，即使新旧rect相同也不误清。stopClippingCursor保留原返回值并阻止立即重入，直到联合信号失效或新的模式/窗口阶段。进程退出最终也由WindowServer销毁该进程的窗口约束，没有持久系统配置。

只注入这个组合dylib，不再同时注入r2后台dylib。内部安装顺序固定：先用冻结逻辑验证并安装foreground保护，再校验其他方法/ivar/native接口，最终camera_warp直接调用原OEM IMP；不会经第二层background wrapper递归委派。unhide/capture/start/stop各保存并调用原IMP。native开关关闭但IDENTITYV_FOREGROUND_WARP_GATE=1时仅后台保护；两个开关均关闭时不安装。保持原DNS等既有兼容库，只拼接本候选；默认binding不变。

Audit沿用IDENTITYV_WARP_GATE_AUDIT=1：启动有foreground/native installed见证，实际warp路径按BOOL context变化最多32条（active/Wine-key/hiddenRequest/ownedCapture/centerTarget/WindowsClip/dragging/lease与原因），无轨迹、键值或逐事件日志，没有热路径getenv或mutex。首次真实验收应先确认已知camera出现ownedCapture1、centerTarget1和lease-enter，再做free/失焦/高速；没有lease-enter不得把设置API存在当约束已生效。free若仍满足全部联合信号，也不能将本候选认定为可靠模式识别，必须记录冲突并关闭该行为。

验证覆盖实际原365 dlopen后NSApp仍nil时，全部新增OEM方法/ivar与NSWindow接口类型校验和native安装；disabled、其他PE basename不装native、background-only只装后台、未知hash不装；errno与原签名对照不变。fixture的960个资格/委派组合及后续场景覆盖：同root、free/unhide、capture释放/owner变化、非中心、focus/geometry/lifecycle、重复center不重写约束、显式Windows clip优先、外部native变化不清、原warp失败、原stop返回FALSE、readback失败不持续重试和±1点边界。没有创建NSApplication、真实窗口、输入或Wine prefix；实际原365/15c字节前后不变。

```sh
python3 wineMousePatch/testNativeCameraCompat.py \
  /path/to/verified-original-runtime /path/to/new-output \
  /optional/path/to/known-unsupported-winemac.so
```

首个raw组合fb903…及日志真值补充版f19436…已退役，不能继续注入。它们保留OEM每次CGWarp/association/队列清理，仅补物理约束与资格撤销，**没有实现高Hz优化，也未证明高速修复**。完整内容区约束不会自动省去warp；既有relative路径仅在已有边界pinned时生效。极小中心约束/relative输入及跳过实际重复重定位属于后续更深语义改变，本轮没有合入。后续唯一runloop版保持这些行为条件，修正启动兼容性后再由Lead按无外部computer-use紫色控制态、保留1k的同一OEM条件，接续focus/capture/free/highspeed与性能验收。

### 启动66的确证、修正与唯一runloop产物

首个实际启动三秒退出66，没有到API/模式验收。invalid_target是Wine先退出后GameActivator报告目标消失（该helper自身失败退出1），不是66根因。仅module/loaddll/seh启动追踪随后闭合：get_builtin_unix_funcs的绝对winemetal.so加载失败，依赖@rpath/winemac.so找不到，winemetal.dll初始化失败，NTSTATUS c0000142低8位为66。旧dlopen wrapper改变libdyld看到的caller image，使原ntdll的@loader_path/链丢失。这是候选自己引入的loader回归；直接绝对winemac探针通过不足以证明加载透明，r2也因此被撤回。

只对非目标musttail不足以解决：实际winemac还可能是winemetal的transitive dependency，根本不会经过一次显式basename winemac.so的dlopen。最终版完全没有dlopen wrapper、__interpose节或_dlOpen导入；不硬编码runtime绝对搜索路径，也不改OEM rpath。启动constructor只读开关，并在已有主CFRunLoop注册高优先before-sources/before-waiting bootstrap observer，类未注册时保持pending，不创建timer/thread/input tap。类注册可查后仅在主线程安装，不在Wine get_builtin_unix_funcs调用栈/virtual_mutex范围内作后置loader工作；NSApp可存在但不能已有key window。成功或identity/type/late等明确失配即移除并释放observer。Audit有一条loaded/main-runloop-pending，再有installed mainThread或skip-late见证；输入predicate/lease日志仍按context变化封顶32。

新增回归从仅直接dlopen扩展到：

- 人工caller.dylib独有LC_RPATH→outer→@rpath/inner；旧f194对普通libouter及目标名winemac.so均稳定失败，无shim和新shim禁用/启用均成功。测试只让caller拥有依赖路径，未把路径添加到shim或可执行文件掩盖问题。
- 实际OEM winemetal无shim/禁用/启用都加载成功；通过caller原rpath间接加载原365 winemac后，运行一次无GUI主loop，native安装成功且NSApp仍未创建。
- CommandGrave→新shim→LoginDNS三库加载顺序与实际transitive安装对照通过；CLI不arm键盘monitor，不创建窗口、prefix或输入。这验证库加载与bootstrap，不等于执行了完整Wine/游戏初始化，真实启动仍是下一验收层。
- 未知hash、disabled、其他进程scope、errno/原签名、960个资格/委派组合及全部lease撤销/显式clip优先/外部所有权/失败fence继续通过；无真实窗口的fixture另覆盖NSApp存在无key可接受、有key/无slot拒绝。原365/15c字节前后不变。

脚本前两参数仍为原runtime及全新输出目录；可追加未知模块、旧坏shim及既有辅助库目录，使全部负控和三库加载回归可重放：

```sh
python3 wineMousePatch/testNativeCameraCompat.py \
  /path/to/verified-original-runtime /path/to/new-output \
  /path/to/unsupported-winemac.so /path/to/retired-broken-shim.dylib \
  /path/to/existing-runner-resources
```

唯一最终raw SHA-256 `73700d28036335693bccee947b4ecd9cdc644b9de97af22c00961f79dc988c2b`；native source `53250998f2ee749aa8f46470fd4723a575fff8ce21d39d003069c0b99b27c083`；test source `fa76baf91899a7d00ac7c34e7e7bf2a6bcef40966375440034d2affe301f8c28`；共用历史source24482a45…未改，其loader代码经编译开关完全排除。Audit明确loaderInterpose=false、mainRunloopInstall=true、highHzOptimization=false、deployed=false。只将该唯一新库用于下一隔离启动，不同时加载旧r2/fb/f194，且不改默认binding或鼠标1k配置。启动已修的静态/探针证据不能预写真实游戏成功、lease已进入、高速不逸出或free/后台验收通过。

### 737实机反证与nullable-capture修补

737实际启动成功，主线程foreground/native双installed见证齐全；自定义中三次ownedCapture1、centerTarget1后有lease-enter，但都紧跟本方release-capture-owner，再回hiddenRequest1、ownedCapture0。明确不按鼠标按钮只快速移动时仍逸出，free跨窗正常。该阶段未持续持有native约束，不能说是native持续有效却失败：Win32 SetCapture在这里是按钮消息路由，并非camera的必要状态。旧中心计算还错误以前置owned条件跳过了纯camera段，只有centerEvaluated0，不能将centerTarget0占位当实际目标非中心。737源码/测试/原件保留为精确反证，不覆盖它再解释成已修。

修补仅限已知IDV/显式opt-in：captureWindow为nil时中性允许，非nil仍须是WineWindow且属于当前key或同root。center在hidden+eligible key下独立计算；仍须实际中心warp成功、焦点/key、无拖动、无Windows显式clip、native空槽等原条件。进入后native lease归当前key窗口，不随nil↔同root按钮路由往返解除；foreign capture、实际key-owner改变、unhide/free、非中心、focus/窗口生命周期、显式clip优先等撤销规则保留。并非只凭隐藏或mouseEnter进入。

一并降低额外热路径工作：在known-hash/type验证后缓存hidden/capture/handler的ivar offset；handler=nil直接判断无Windows clip；原几何refresh时用OEM flip缓存Quartz中心，普通warp只作点差；已有window:isBeingDragged:方法变化后读取原set完整count维护drag缓存，多窗口不能用单个BOOL覆盖。首次enter/readback和退出才读写native约束，不每次recenter设置。仍逐次委派OEM原IMP，原lastWarpTime、pending清理与位置基线均未改，不吞warp、不伪造成功。

737主game installed后startup observer已在同callback移除；未加载图形类的helper可能仍pending，旧版每runloop活动会查ObjC类。新版add-image回调仅dladdr及原子标记winemac映射，不包装loader；未见该图像时observer只原子判断，不查ObjC。成功/明确失配仍移除。没有timer、worker、输入tap或热路径getenv/日志风暴。

新版实际无GUI元数据probe验证新增ivar类型及原OEM window:isBeingDragged:的void/object/BOOL签名；完整rpath/真实winemetal transitive/三库加载、disabled/scope/hash与原errno/签名回归继续通过，NSApp未创建。合成fixture的960组合增加nil进入与nil→同root→nil连续lease、foreign即时撤；多窗口A/B拖动在A释放而B仍拖时保持drag，最后B释放才清。10000次连续无按键center调用没有额外frame/flip/capture/controller-clip/drag-count/native-rect查询或native重写；这只是Fake对象的结构性调用计数，不能当实际CPU/FPS/输入流畅证明，必要active/key/kind门及原OEM定位成本仍在。

新版唯一待实机产物raw `ae1c5cab9af3e7b9af00ab9d043dbecffe781a65c97d596af2cd2b4b04b23e9c`，source `2605ee7b616fff800c6e6dac2e5b324b5c42a4dbeececdf2a9b5cee6c22b2d29`，test `3dbc41716cbcb80a1505d429415c18dbf71539015d457e3ba9ccb54c584f22f5`。737及更早版本均不能继续作为下一注入候选。默认binding未改；当前真实基线由Lead维护，未向活动进程注入或覆盖原365/15c。

### 当前性能分支与可观察边界

此前同鼠标8k配置→1k同会话显著改善的事实保留，不据后来变化倒写无效；随后用户又感到特别卡，737因此有回归嫌疑。只读仍为1000Hz、DPI原始字段4（初次5），本任务/typed helper只有先前一笔polling写入，没有DPI写入，不归因谁改变，也不自动恢复硬件。撤候选后体感“似乎流畅些、未到最好”尚不能定候选就是根因。隔离runner的HUD读取条件已由Lead对齐；当前无shim、1k、HUD正常开启的基线中，用户进一步表示鼠标与触控板表现一样、未见帧率异常、像输入卡顿。成熟呈现数据单独导出，不把此前会话的坏呈现记录或8k线索直接套成当前cause。

共享链的已知源码机制是：无SetCapture的mouseMove要windowNumberAtPoint与内容区hit-test；目标为WineWindow后，timestamp不晚于lastSetCursorPositionTime直接丢弃；成功warp写systemUptime、重新association，随后清全部pending move与重设按钮/滚轮基线，下一新move强制ABS；队列虽然合并move，仍逐post写pipe。鼠标/触控板共用这些环节。OEM注释指出CGWarp会隐式disassociate约0.25秒，并已有suppression0/恢复0.25与Associate(true) workaround，不能只凭注释断言当前macOS失效。

若成熟Metal正常而只缺输入定位，最小额外观察可限定在现有mouseMove/warp callback、显式opt-in、稀疏1/128且总64样本，统计eventAge、原IMP服务耗时、前后lastWarpTime及lastTarget非空状态，不记坐标/键值。前后lastTarget均非nil且stale timestamp的子集可确认早退；目标变nil可识别无Wine target；双方nil必须标ambiguous。原warp方法服务时间不包含此前OnMainThread等待与Winserver RPC。不能无锁窥队列数组硬算drop；精确pending丢弃计数需要在原锁下predicate中轻计数并另做类型验证。该额外统计当前未实现/未启用，不另造纯诊断会话，也未用新nullable候选预写当前输入/呈现结论。

后续已取得当前性能干扰的有效同进程对照：无shim、HUD已正常开启、配置仍1k/raw4的同一游戏进程，AX核对Monitor绑定正确，联合采集completed后界面仍显示采集中，Monitor CPU快照31%。Lead关闭浮窗、不重启游戏、不改硬件，确认浮窗off且画面采样未在进行，Monitor降至1.6%；用户明确反馈“明显改善或已恢复正常”。同进程对照支持关闭浮窗后的CPU和输入改善，但陈旧采集状态不足以证明SCK流当时仍存活，31%负载的确切原因尚未独立证实。资源查询的5次只读样本约1.4–1.9ms，未重现或解释31%负载，详见[工具箱验证](../maintenanceToolboxApp/README.md#画面流与资源浮窗的生命周期修复2026-11-07)。不再需要前述64点shared-input诊断，不新增hook/画像，也不把当前卡顿归因尚未证明的warp/filter故障。历史8k配置对照及先前实际坏呈现独立保留。Toolbox浮窗改为仅资源数据、视觉采样留显式联合采集由独立工作域接续；鼠标源码/测试/ae1c产物继续冻结。下一真实fast/free/focus验收固定1k/raw4、HUDon、Floatoff，无外部computer-use控制态；若通过仍须接续正式原件兼容层集成与构建闭环，不能只交候选便终结鼠标目标。

### ae1c实机fast/free通过，转向native handler协议

在1k/raw4、HUD正常开启、浮窗关闭、无外部控制态的真实会话中，ae1c主线程foreground/native双installed，nil captureAllowed1、center1后持续lease-enter；nil↔owned按钮路由变化保持lease1，~free有release-unhide，最终失焦有release-focus。用户明确“自由正常，捕获现在不会溢窗”。这一高速边界/free结果保留；输入体验仍未达标。用户后续纠正的是“走动同时用鼠标转视角才抽搐/拉回，纯键盘角色转向正常”，覆盖先前固定视角斜走的说法；~free不能等效比较且已skip，不再等待该不成立的物理测试，也不把网络/固定视角解释当已证原因。

源比较确认了driver局部状态不一致：direct NSWindow rect已物理pinned，但原Cocoa clipCursorHandler=nil、clippingCursor=false，原handleMouseMove在computedPoint越客户区、仍处desktop内时继续ABS；真正native handler.active有cursorClipRect时在同一边界使用RELATIVE，并累积delta/保留整数截断余数。整窗内部及每次warp后的强制首个新ABS仍相同，lastWarpTime过滤、CGWarp/suppression/association及队列清理也不会自动消失。无SetCapture的ABS路径另有每move update_window_zorder RPC，RELATIVE可避开该处但整窗interior仍ABS。它是具体输入语义缺口，不能承诺解释或根治全部主观抖动。

[原片段分类测试](../wineMousePatch/testPinnedBoundary.py)从匹配CW源提取原分类分支直接编译，64例中5组客户区pinned边界呈direct ABS/native-aware REL差异，interior、微小delta及强制首ABS行为保留；fragment SHA-256 `93e19828fee4f348cc8c76caf26a7c7d2ae374702f21522838d1d07590c475f5`。只使用合成对象，无Window/NSApplication/真实输入，不将分类证明当手感改善。

新增独立[协议候选](../wineMousePatch/native_protocol_compat.m)和[验证脚本](../wineMousePatch/testNativeProtocolCompat.py)，ae1c源码/测试/产物均原样保留。native-only进入时先校验原front确为当前key，显式创建准确WineConfinementClipCursorHandler，暂借原inactive handler slot，预置真实native对象后调用原Controller.start。非nil slot使原chooser分支不可达，不走EventTap fallback。原handler维护active/rect/windowNumber，不强写BOOL；driver状态因此与实际native约束一致，Winserver explicit clip状态不写。本方owned handler token只用于区分adapter local clip和真正Windows请求，不改原clippingCursor getter。

原start会再次回中并updateWindowsForCursorClipping，过渡fence完整委派这次原warp、避免再次自动进入；仅在该owned start过渡内把front getter pin到已核对key，使原handler不会选另一Space的WineWindow。返回后校验实际native rect、native active/windowNumber、slot和几何/焦点，失败完整退出。MRC slot的既有+1在借用时转由lease保管，新对象另有slot和adapter两份引用；退出归还原inactive slot，再成对释放新对象。外部修改native rect时不调用会清零的原stop，外部替换slot时不恢复覆盖它；Windows显式start先归还本方slot再原样处理。free/noncenter/focus/move/resize等原生命周期保留，Retina原方法全段另有fence并先释放本方，防其内部回中重新捕获后被继续缩放。没有吞定位、写硬件、shared-input诊断或新timer/thread/input tap。

#### 原CW所有权/析构依据

已从既有CodeWeavers 26.1源码包直接取未打补丁文本复核，不能将EventTap实现的dealloc误套到native：

| 原源码位置 | 行为与本候选引用依据 |
| --- | --- |
| Wine源`dlls/winemac.drv/cocoa_cursorclipping.h:60` | Native直接继承NSObject；不继承EventTap。 |
| 同目录`cocoa_cursorclipping.m:425–507` | 完整Native实现没有dealloc；只有显式stop487–495会在490清native rect、492将active置false。释放native对象不会隐式stop/clear外部rect；文件129处dealloc属于EventTap。 |
| 同目录`cocoa_app.m:1329–1348` | Controller.start仅slot nil时alloc/init取得+1，非nil预置后不再chooser/retain；然后调用handler.start、额外setCursorPosition与窗口特性更新。 |
| 同目录`cocoa_app.m:1351–1364` | Controller.stop只调用handler.stop、写lastSetTime、更新窗口，没有release或清slot，因此候选的归还/两份release不会与stop重复。 |
| 同目录`cocoa_app.m:215–236` | 真正的slot release在Controller.dealloc221；lease另保活controller，并在退出前恢复其合法slot，符合原MRC所有权。 |

原native文本SHA-256 `082d079412a955cf96c1e948a5a8c1921daba7cab21f92ecf2259a2688c4347d`，Controller文本 `b9d0434dc8ecaf0379f8300e94f2e8c70b3b320c45b4cb9f7d6877acd2e94c30`，header `55305632801cded83ec9c464e340a931fd109088e2eed064f32297242192d0e2`。没有为所有权审查启动新GUI/输入探针。

协议候选实际OEM新增方法/ivar类型、主loop/transitive/三库加载、disabled/scope/hashnegative/errno签名回归通过，仍无dlopen interpose。960组合增加原start额外warp计数、重入、inactive slot归还、foreign slot/rect保全、Windows优先、失败与Retina内部嵌套warp不得重入；多窗口drag与nullable连续lease回归保留。10000合成调用检查仅候选额外查询，不包含真实原handler每move clamp/ObjC成本，不可当实际性能证明。

唯一下一协议候选raw `1823d00720d3809c2f5b8d4d4e624b98879adba0280134ffe68f9cd34eda2e13`，source `86287183653b58d8db94cb6328c25c9e8769150dd778aea3046eff65b4bcf8d1`，test `4fe10b42d7910da28ff31cd742f06afd960b89260fe7425a019387195eddfba6`。依赖仍仅CoreFoundation/libobjc/libSystem。冻结当时尚未部署、未碰活动ae1c会话；该时点尚待的实测已由下段后续正式验收闭合。原handler带来的额外一次进入回中、stop时间戳及窗口移动/resize特性更新都是实际差异，不隐去，也不预写性能改善。正式构建入口与集成由Lead维护，接入及默认加载结果见下段。

后续真实1823协议实现（签名副本b94）在HUDon、Floatoff、1k/raw4一致条件下，用户明确“没到Windows原生感觉，但明显好很多、没有新问题”，并确认完整全屏、高速不逸出、free跨窗、失焦后台指针经过、回游戏恢复全部正常。物理边界验收至此闭合，残余主观体验差距保留，不再扩shared-input诊断。Lead已接续两canonical runner及正式构建链的Native/BG默认1，保留各自显式0退出；新增[注入契约](../gameRunnerApp/tests/nativeCameraCompatContract.test.command)实跑40个fake x86 final Wine child，验证两runner/两产品/direct与virtual、默认与独立optout、准确普通非symlink资源、实际DSO加载、非SIP ARM resolver/control不染、PID/fallback保留。未启动真实Wine/游戏/HID，冻结protocol/shared/test/classifier均未改；正式App29随后由Lead完成完整构建、签名和安装：代码来源cd73b651a95896ee4b9bde76ad0c3887f6d335c0，27个第一方Mach-O身份与新增40组合启动合约通过。清除Native/BG/Audit测试环境后，从实际安装runner按默认mainland启动，通过只读进程映射核对，真实游戏进程明确加载安装包Resources/IdentityVNativeCameraCompat.dylib，签名资源SHA256为c8acedbb55786a902ed50f4f663b77ee1e1436636af2d755ec0f26bc09b55b58；实际加载winemac仍为`365fefb1c0bf4c0e54f4fd3a00dbd44bd9a6febc75209846b6de2c270bdb9c60`、win32u仍为`15c047bb78a84da940eb86eff692e6aa6b74ed69975613c93715b9f3ce0f13f7`，默认绑定未变，HUD配置accepted1。Audit默认关闭时安装日志也静默，不能据此判未加载；本次以实际映射、包签名/源码身份和先前同源完整物理验收闭合，不再要求用户重复动作。原始会话证据保留仓外，公开可复核的依据是上述日期/build/source、资源完整摘要、进程映射方法及同源物理验证条件；该开发构建的sourceClean=false如实反映构建时文档收尾，不用于公开发行。
