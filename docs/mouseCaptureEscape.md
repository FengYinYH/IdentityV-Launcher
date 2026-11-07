# 瞄准捕获模式鼠标逸出：调查与隔离候选

2026-11-07。用户报告按 `～` 进入瞄准捕获后，高速移动鼠标会逸出游戏窗口；明确要求保留自由模式跨窗口移动。本轮任务允许源码调查、日志白名单检索与独立候选，不允许启动游戏、发送输入、部署或修改 runtime manifest/catalog。历史的“单次捕获完全丢失”与本次“高速逸出”分开处理，不能自动视为同一故障。

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

[诊断补丁](../wineMousePatch/confinement-session-diagnostics.patch)应用在状态核验补丁之后；[构建配方](../wineMousePatch/buildCandidate.command)现按 reset → 状态核验 → 会话诊断顺序应用。默认关闭。仅对待取证的 Wine 启动进程显式设置：

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

验证：在原14项状态检查上，扩充实际 handler 提取测试，以内存窗口/指针/时钟替身验证默认关闭与精确开关、内界事件不读系统指针、四类异常、秒级门、epoch 去重、64条上限及达到上限后停止读回；多次越界调用没有修改约束。测试没有真实 NSApplication/窗口/输入。诊断模块增量编译成功，x86_64、minOS14.0，3个导出和全部依赖身份仍与现用模块一致。诊断产物 SHA-256 为 `8021c3e6c9abe189c8fd769682b1de7df767374a657395df1101da28c155ef79`；仍未签名/部署，也未进行真实 Wine/游戏取证。前一状态候选 `fed1f081…` 已单独保留，构建目录的默认输出目前为诊断候选。
