# 游戏启动表现：窗口位置、Dock 名称与图标外形

本专题对应 RC6。1.0 保留固定 1080p，不开放自定义分辨率；窗口面板重构留到 2.0。本次只处理启动时的位置、实际 Dock 名称及现有游戏图标的外轮廓，不改游戏渲染内容、DPI、像素比例或保存的分辨率。此前依据见[窗口与登录调查](windowAndLoginInvestigation.md)，规划正本见[开发计划](developmentPlan.md)。

## 最终实现与入口

- [`gamePresentationHost.m`](../gameRunnerApp/gamePresentationHost.m) include 进现有 ARM [`IdentityVLauncher.c`](../gameRunnerApp/IdentityVLauncher.c)。内部 `--prepare-game-host` 早分支在创建 NSApp、显示对话框或启动 runner 之前执行；只生成用户侧元数据和受控 loader 符号链接，没有新增 helper binary、DSO、daemon、Python/CLT 运行依赖。
- [`gamePresentationHost.command`](../gameRunnerApp/gamePresentationHost.command) 是两 runner 共用的 Zsh 资源，由 [`buildGameRunner.command`](../buildGameRunner.command) 分发。只在最终 Wine child 内解析规范名称、调用 ARM 元数据模式，然后设置该 child 的 `WINELOADER` 并 exec host alias；desktop/direct 两分支一致。调用发生在 x86 `DYLD_INSERT_LIBRARIES` 和 native camera flags 导出之前，ARM helper 不会吃到 x86 注入。
- 窗口与图标逻辑位于 [`IdentityVGamePresentation.m`](../wineKeyboardPatch/IdentityVGamePresentation.m)，由原 [`IdentityVCommandGraveForwarder.m`](../wineKeyboardPatch/IdentityVCommandGraveForwarder.m) include，沿原 x86_64/minOS14/AppKit/ARC DSO 出货。构造器主线程同步早装，不抢先创建 NSApplication；保留原输入/音频代码和独立原生鼠标模块。

两服名称白名单为 `第五人格` / `Identity V`，来自既有 manager 的 `game-display-name`。child 内将 `IDENTITYV_GAME_DISPLAY_NAME` 与 `WINEPRELOADERAPPNAME` 同步。表现安装另要求 argv 有完整 `dwrg.exe` 末级文件名；单个 Windows 反斜杠先转换成 `/`，不接受 `.bak`、`--name=dwrg.exe` 等相似参数。没有新增用户设置或空壳 Agent 业务命令。

## 为什么需要实际命名的 host

游戏 AX 窗口标题一直是“第五人格”，回退的是应用注册/Dock 名称。真实对照已证明：CFBundle 缓存、`NSProcessInfo.processName`、`NSRunningApplication.localizedName` 以及 Dock tooltip 是不同证据。外部 getter 中文并不表示 Dock 中文；前台注册前/后 LS setter 都成功的候选，真正 live Dock AX title 仍为 `wine`，且没有旧 pin/filelabel 或第二个同 bundle 应用可归因。

独立原生对照进一步把原因缩小到注册的 bundle URL：无 `.app` 可执行对应的 Dock 标题取所在目录显示名；同一已签二进制放进 `GameHostProbe.app`、内部 CFName/DisplayName 都改中文，Dock 仍叫 `GameHostProbe`。把真正目录命名为 `第五人格.app`，再用其内部 symlink 执行原 loader，实际 Wine 游戏的 Dock AX title 才成为“第五人格”。因此最终使用适当命名的轻元数据壳，生产不再安装 LS/CPS 名称 setter、activation-policy 包装或 setenv 重挂。

host 只支持已验证的 `codeweavers-wine-release-dxmt` profile，核对原 loader 的 embedded vendor identifier `com.codeweavers.CrossOver.wineloader` / `APPL`。公开 `CFBundleCopyInfoDictionaryForURL` 明确支持读取 unbundled Mach-O 的 `__TEXT,__info_plist`；完整复制原 Info，保留 vendor identifier、用途说明和其他原属性，只设置名称、实际 executable、Game Mode/游戏分类与高分辨率属性。缺失麦克风用途说明时补游戏语音说明；元数据本身不请求权限。

用户侧布局为 `GameHosts/v1/<product>/<metadata generation>/第五人格.app` 或 `Identity V.app`，内部仅有 Info 与指向原核验 loader 的 `Contents/MacOS/wine` symlink。generation 由包含 canonical loader 路径的元数据摘要生成：runtime、元数据或模板变化进入新代，不改活跃 host。不存在 Wine 二进制复制、重分发、重签、OEM 文件改写、全局 Dock 配置/重启或全局 LS 注册。

现有对象只有完整元数据、真实目录、受控绝对 symlink 都匹配才复用；未知对象、cache 链接祖先、只读路径、无效 profile/名称等透明退回原可启动路径，不替换或删除用户内容。先按调用者原始 cache 路径检查链接祖先，再作后续路径处理：Foundation 对已存在的 `/private/var` 路径作 standardization 会折成 `/var` 链接，曾使首次生成成功、重复复用却被误拒；完整构建的默认临时目录合约已暴露并修正此问题，仍保留拒绝调用者自带 cache 链接的边界。并发创建采用独占 UUID 暂存与一次发布，另一个相同合法 winner 可复用；仅清理自身已核定的暂存目录。上层 `WINE_BIN`、registry/readiness/resolver/manager、supervisor `--expected-executable` 仍指向原核验 Wine；host symlink 与其是同一文件，最终 child 的 `WINELOADER` 让后续实际游戏 exec 保持 host。

## 权限行为与验证边界

复制原vendor标识与用途说明不等于所有系统权限决定必然继承。本轮用户实际观察到游戏「本地网络」提示；网络权限服务日志也记录了命名host使用同一vendor标识重新登记和权限缓存更新，支持应用识别变化这一线索，但尚未定位具体触发权限的游戏/Wine网络调用。元数据核心没有新增网络设备扫描、设备信息收集或权限数据库修改，OEM loader仍为原字节。该提示已纳入三语发行说明；不能据此声称已扫描/上传设备信息，也不能保证拒绝权限不影响既有网络功能。系统授权保留给用户决定。

## 锁定上游路径依据

依据 `crossover-sources-26.1.0.tar.gz`，SHA256 `e4ec87d5821a009dd1f1d2e36ffe2e24b8fcbae9516375ea42f95a16928ab8fa`，成员前缀 `sources/wine/`：

- `loader/main.c`：`get_self_exe()` 读取 `_NSGetExecutablePath`，但 `try_dlopen()` 先 `realpath_dirname()`，所以 host symlink 最终回到原 loader 目录找 `ntdll.so`；不需要重排库 root。成员 SHA256 `9d4f878e150e6971ae96be60478cb6df6a9bc2f380d10a29fa2a9c01d1a4de67`。
- `dlls/winemac.drv/cocoa_main.m`：主 runloop 创建 `WineApplication` 后进入 `[NSApp run]`。成员 SHA256 `a6feb609a5e729000f9217484b352d4d3a5696875748d1c79b26bb380099eaf5`；辅助库不能抢先创建普通 NSApplication。
- `cocoa_app.m`：`transformProcessToForeground:` 先 regular policy，再构建菜单、设置应用图标。`setApplicationIconFromCGImageArray:` 的回退提供各尺寸 `NSBitmapImageRep`。成员 SHA256 `b9d0434dc8ecaf0379f8300e94f2e8c70b3b320c45b4cb9f7d6877acd2e94c30`。
- `cocoa_window.m`：`windowDidMove:` 经 resize/frame 通知链把位置发回 Wine；公开 `setFrameOrigin:` 保持尺寸并沿该链同步，不写私有 frame 槽。成员 SHA256 `b7799976aa6446051cc0e10b55fff6474943af873b61c25df7856b28b7e1eb0f`。

## 有界的一次居中

全部在游戏进程主线程完成，不调用 AX、不观察其他进程、不请求屏幕录制/辅助功能权限。

1. 安装后总观察最多 90 秒；绑定第一个可见、带标题栏、普通层级、无父窗/sheet、内容至少 600×300 点的 `WineWindow` 后，再给最多 30 秒，且不超过总截止。500×500 工具窗和菜单窗不成为候选。
2. 内容 view 的 `convertRectToBacking:` 达 1920×1080 像素（允许 ±4 像素舍入），外框稳定 0.5 秒才移动；revision 拒绝过期回调。这里的 1080 是 backing 像素，不是强改为 1080 逻辑点。
3. 用窗口当前屏幕 `visibleFrame`、AppKit 底部原点逻辑点居中；支持负坐标显示器。超出可用区域时左上角对齐，让标题栏/红绿灯可达，内容尺寸不变。
4. 用户开始移动、live resize、系统全屏、最小化/关闭会取消。屏幕参数通知使旧稳定回调失效、在原截止内重新观察当前 screen/geometry；不能因首次前台/菜单注册也发通知就直接退出。成功/取消/超时拆除全部观察者，之后不纠偏，没有常驻 timer。

真实 2x 样本内容为 960×540 点、外框 960×568 点；可用区域 `{0,0,1920,1050}` 对应 AppKit origin `{480,241}`，CG 顶部原点 `{480,271}`。早期小窗绑定约 0.15 秒后的屏幕通知曾导致原候选提前退出，已以“绑定小窗→首次屏幕通知→最终尺寸→居中”fixture 固化修正。冷启未到最终尺寸/超过有界期限则结束，不为满足检测写游戏配置。

## 图标与审计

仅包装公开 `setApplicationIconImage:`，保留原 IMP 并限定当前 `WineApplication`。对每档原位图按短边 20% 半径做圆角矩形 alpha mask；保留原像素尺寸、逻辑尺寸、色彩空间、比例与中心内容，不换图、不内缩、不加背景/阴影/描边。原半透明 alpha 保留，关联标记防重复 mask；无效/不支持或过大表示保留原对象。

维护者可显式设置 `IDENTITYV_PRESENTATION_AUDIT=1`，默认关闭，最多 32 行 JSON，终止原因保留预算、重复状态去重。记录匿名窗口序号/类、frame/content/view/bounds/backing/scale、style/level/parent/visible、候选/稳定/finish 原因；图标只记录 representation 类型/大小、是否 mask、角/中心 alpha 和中心保真布尔值。不记录窗口文字、输入事件、图像内容或截图，也没有任意输出文件参数。

禁止激活的原生桥接 fixture 比较同一 AppKit 路径的 unmasked baseline 与 masked getter：当前 2x getter 可返回浮点/色管表示，不能把其原始整数位或 DeviceRGB 字节直接当作颜色比较。真实 Wine 图标已读到 128×128 bitmap、mask 命中、角 alpha 255→0、中心颜色保留。

## 保留的反证与退出的分支

[`GamePresentationLegacyNameAdapter.m`](../wineKeyboardPatch/GamePresentationLegacyNameAdapter.m) 仅被独立 probe include，保留“LS getter 中文而 Dock 仍 wine”的对照；生产没有此 SPI。当前系统 CPS wrapper 使用相同 LS display-name key 的观察只说明该包装的实现，不能扩大为所有 PSN/ASN 情况的保证；最终没有依赖它。

[`GameNameLoaderProbe.c`](../wineKeyboardPatch/GameNameLoaderProbe.c) 仅注入原签 `--version` 路径，沿原 `_NSGetMachExecuteHeader()` / `__TEXT,__info_plist` 读真正内存，原参数/原返回透传观察同范围 `vm_protect` 与 `unsetenv`。实测：

| 输入来源 | unset 后原指针 | 原保护请求 | raw 名称 |
| --- | --- | --- | --- |
| A：继承已匹配 WINEPRE，不重挂 | 12 字节仍匹配 | RWX\|COPY 成功，恢复 RX 成功 | 第五人格 |
| B：缺失后 setenv；C：匹配后 setenv 覆写 | 长度变 0 | 原函数在 strlen 后早退，未请求保护 | CrossOver-Hosted Application |

该样本原 Info 字符串偏移 4597、容量 28、页大小 4096；`__text` 偏移 1920、长度 1234，页不交叠。原 loader 的 allow-dyld/allow-jit/unsigned-executable-memory/disable-library-validation 权益存在；没有证据支持以缺权益为由重签或退保护。生产已移除 setenv 重挂；[`IdentityVGameNameBootstrap.h`](../wineKeyboardPatch/IdentityVGameNameBootstrap.h) 仅是保留对照的 probe 输入工具。不能把变量消费推成 raw 写对，更不能把辅助 `--version` 代替实际游戏 Dock 判定。

## 重放与验收

```sh
zsh gameRunnerApp/tests/gamePresentationHostContract.test.command NEW_HOST_TEST_DIRECTORY
zsh wineKeyboardPatch/gamePresentationSelfTest.command NEW_PRESENTATION_TEST_DIRECTORY
# 可选历史输入所有权对照：原签 loader --version，不启动游戏/创建 prefix
zsh wineKeyboardPatch/gamePresentationSelfTest.command NEW_PRESENTATION_TEST_DIRECTORY ORIGINAL_SIGNED_WINE_LOADER
zsh gameRunnerApp/tests/gameModeMetadataContract.test.command
```

host 入口编译实际 ARM 核心与无 GUI fixture，覆盖两服/两名、symlink 执行后真实 bundle 身份、原 Info/用途/标识保留、复用/并发、异常对象/只读/别名回退、原 loader 字节/签名不变和两 runner 精确 desktop/direct child 片段。表现入口直接编译生产代码，覆盖窗口有界状态机、zsh 真实 Windows argv、多尺寸像素/alpha/幂等性、禁止激活的原生图标桥接及独立 LS 历史对照，生成孤立 ad-hoc DSO。两者不启动真实游戏或发送输入。

正式源码链已由整合者真实启动验收：采用冻结的 ARM helper、两 runner 的规范脚本、共享资源及生产 DSO，没有私有 exec 覆盖；启动日志确认 metadata host ready，实际用户缓存自动生成 `GameHosts/v1/mainland/<generation>/第五人格.app`。fresh Dock AX title 为“第五人格”、bundle URL 指向该自动生成 host；主窗 CG `{480,271}`、外框 960×568，生产日志对应 AppKit `{480,241}`；实际图标 128×128、mask 命中、角 alpha 255→0、中心颜色保留。默认引擎/OEM loader 与冻结输入模块的原字节未改变。

此前 proper-host 会话另作 AX **程序化**移动至 `{520,301}`，1.5 秒仍保持，再程序化恢复成功；这是启动后不回拉证据，不能称为新增物理拖动测试。两服/两名称的元数据、native bundle 身份及 desktop/direct child 合同已通过；国际服与英文名称的真实游戏启动尚未实测，不将 fixture 通过外推为其整套体验已验收。后续完整应用的正式发行构建、签名、公证与发布由整合流程接续。

CG owner 旧标签与 `NSRunningApplication.icon` 的 generic exec 读数都不能替代真正 Dock title/图标链；不为这些缓存扩大系统修改范围。
