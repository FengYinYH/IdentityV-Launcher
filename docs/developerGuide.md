# 开发者指南：项目框架与维护入口

接手开发先读[项目状态](../STATUS.md)和[开发计划](developmentPlan.md)：分别给出已实现/待验证/未知、近期需求/未决设计及下一步。窗口与登录问题从[调查汇总](windowAndLoginInvestigation.md)续接；下载核心的历史判断、锁定版本 304 证据及后续复现见[下载核心专题](downloadCoreUnification.md)，音频设备切换边界见[音频专题](audioDefaultDeviceFollowing.md)。不依赖仓外聊天或报告。任务结束同步上述正本与相关专题；本文继续负责模块关系与构建维护顺序。

这是已有 macOS 开发基础的维护者接手本仓时的路径。玩家的安装与使用看[项目首页](../README.md)；逐个顶层对象及脚本副作用看[项目地图](../projectMap.md)。本页说明模块如何协作、从哪里改、如何验证，不重复目录清单。关键取舍与兼容原因在[工程边界](engineeringDecisions.md)和[第一方身份迁移](firstPartyIdentity.md)；发行材料与签名分别有[封包](../releasePackaging/README.md)、[签名](../signing/README.md)说明。

## 开发、构建与持续检查

营销版本、build和源码提交各有职责：日常开发只递增交付build，公开发行阶段确定时再调整营销版本；详见[版本约定](../releasePackaging/versioning.md)。常用项目入口保持一个，临时worktree在整合并保存所有修改后退役，构建与上传暂存放Builds对应项目下，不留在Projects顶层。

CI入口不按RC命名：`.github/workflows/checks.yml`跑持续合约检查，`.github/workflows/integration.yml`仅在手动选择时做图形/首装/启动/公告实验，默认只探测图形、不下载游戏。测试使用本次确切提交，App报告携带实际build；发布时引用最终提交相符的结果。旧临时实验的绿色范围、当前本地整理与远端状态分别记录在[CI说明](ciWorkflow.md)，不把通用检查、实验或公证任一项等同全部发行验收。

关于与版本/更新窗口复用 `LauncherUpdateView.swift` 的排版和外框几何；开发验证可直接运行App可执行文件 `--preview-launcher-update --preview-language zh-Hans`（另支持zh-Hant/en），在业务模型创建前进入隔离原生预览，不联网、不下载/安装，不写真实更新状态。纯视觉入口无需新增Agent业务命令，几何与三语验证见[窗口说明](aboutAndUpdateWindows.md)。

IDV Login的DNS适配在helper合约11的停止服务生命周期内准备，按精确官方资产身份注册，未知版本透明退出。旧8–10的管理协议仍可用，当前维护能力需单独判断，不能由“进程ready/旧协议兼容”跳过修复安装；细节见[DNS说明](loginDnsFallback.md)。鼠标协议兼容层已默认集成并完成物理验收，现行重建与测试见下节；历史隔离模块及失败依据保留在[鼠标专题](mouseCaptureEscape.md)，不再按旧候选替换OEM模块。

### 原生鼠标协议兼容层

玩家构建最前调用[`buildIdentityVNativeCameraCompat.command`](../buildIdentityVNativeCameraCompat.command)，编译[`native_protocol_compat.m`](../wineMousePatch/native_protocol_compat.m)（include [`foreground_warp_compat.m`](../wineMousePatch/foreground_warp_compat.m)），生成x86_64/minOS14的`IdentityVNativeCameraCompat.dylib`，ad-hoc签名并暂存到两份项目runner模板资源，重签模板；该入口不安装到`/Applications`，不替换OEM Wine模块。最终发行签名由玩家构建/签名流程继续处理。

两runner仅在最终Wine child默认设置`IDENTITYV_NATIVE_CAMERA_CLIP=1`与`IDENTITYV_FOREGROUND_WARP_GATE=1`并加载资源，ARM resolver/control不受注入。显式`0/0`退出全部适配，`1/0`为Native-only，`0/1`为BG-only；未知OEM身份透明退出。使用这两个完整环境变量名设置独立开关，不能把Audit静默视为未加载。

从仓库根目录重放无GUI测试；各`NEW_OUTPUT`须为独立新目录，不能指向活动资源：

```sh
python3 wineMousePatch/testNativeProtocolCompat.py OEM_RUNTIME NEW_OUTPUT [UNKNOWN_WINEMAC [RETIRED_BROKEN_SHIM [RUNNER_RESOURCES]]]
python3 wineMousePatch/testPinnedBoundary.py matching-cocoa_app.m NEW_OUTPUT
zsh gameRunnerApp/tests/nativeCameraCompatContract.test.command
```

方括号表示逐级可选参数，实际调用时移除方括号并替换路径。OEM_RUNTIME须匹配原365/15c模块摘要，测试会检查；classifier输入来自锁定`crossover-sources-26.1.0.tar.gz`（SHA256 `e4ec87d5821a009dd1f1d2e36ffe2e24b8fcbae9516375ea42f95a16928ab8fa`）的`sources/wine/dlls/winemac.drv/cocoa_app.m`，全文SHA256 `b9d0434dc8ecaf0379f8300e94f2e8c70b3b320c45b4cb9f7d6877acd2e94c30`；原handler/header成员与摘要见[所有权依据](mouseCaptureEscape.md#原cw所有权析构依据)。来源归档及许可已由发行材料锁定。这些测试验证类型、协议、加载/退出与runner边界，真实窗口/高速/free/BG/focus验收另见专题。

旧`testForegroundWarpCompat.py`对应已退役的dlopen包装，保留作失败历史/负例，不能据其通过部署旧loader；现行协议测试的`RETIRED_BROKEN_SHIM`参数用于重放caller-rpath负控。

## 运行与构建关系

本轮候选的语言和来源维护见[语言说明](launcherLocalization.md)、[IDV Login 来源与固定更新策略](idvLoginSourceAudit.md)。登录策略通过原生状态工具生成受管 overlay，helper当前维护合约为11；升级组件时必须复核冻结模块加载和策略版本门，不能只更改 asset manifest。

IDV Login 版本升级须同步清单、Swift UI/cache 常量、Go 下载器精确字节锁和许可来源；当前锁定官方 `v6.3.3-beta`，标签与资产以实际 Release 核验，不能由版本号猜测通道。通常先退出游戏再运行安装器。已明确安排保留活动游戏的维护更新，可先停止登录代理，再使用安装器的 `--allow-running-game-with-stopped-proxy`；此参数仍要求代理进程和托管 hosts 均已消失，不提供活动代理绕过。具体证据与回退见[组件说明](../idvLoginComponent/README.md)。

玩家 App 的界面和调度位于 `playerLauncherApp/Sources/`。`LauncherUpdateChecker/Installation/Agent.swift` 与独立 `UpdateHelper/` 共享更新流程；只有显式Agent旗标进入CLI，启动回执保留给GUI。事务锁、挂载/超时/回退取舍与验证范围见[更新专题](engineeringDecisions.md#用户确认后的-macos-更新事务)，接口见[CLI契约](agentCLI.md#启动器本身的更新)。`Tests/updaterSelfTest.command`只运行离线checker/假App事务/锁与回执测试并编译助手，不替换App。下载与校验依次由 `productCatalog/`、`productManager/`、`manifestPlanner/`、`gameDownloader/` 等模块负责；国服和国际服首装及完整性修复共用 manifest planner 与网易 `downloadIPC.exe` supervisor，国际服通过显式 `oversea` 路由保持 LoadingBay 产品身份。国际服 adapter 仍独立解析并校验官方清单及安装器地址；两服的发布事务和游戏路径绑定保持分开。共链证据及边界见[网易下载核心共链说明](downloadCoreUnification.md)。共享 Wine/DXMT 输入由 `runtimeManifest/` 与 `runtimeBootstrap/` 锁定、取得和核验。玩家点启动游戏后，内嵌的 `gameRunnerApp/IdentityV-Mac.app` 承接启动命令，调用 Wine，再进入游戏。`gameRunnerApp/IdentityV-AGTK.app` 是历史/开发模板，不在当前玩家 App 内出货。

RC1 升级时，ProductManager 的状态/操作入口在空闲状态执行[默认目录一次性迁移](rc1UpgradeMigration.md)。迁移与安装操作共用受管写锁，并由独立 journal 保存小配置/链接回退；活动游戏延后迁移，读取原记录仍可识别它。新名称由现有 `wineKeyboardPatch/` 原生辅助模块在 AppKit 创建菜单前适配，原因和无窗口系统名称回归见[语言说明](launcherLocalization.md#游戏宿主菜单名称与缓存时序)。

维护者工具箱的 UI、浮窗和采集在 `maintenanceToolboxApp/Sources/`，独立构建与安装。两款 App 显式编译 `sharedDiagnostics/` 的健康、采样、采集状态和受限旧偏好迁移源码；工具箱不调用玩家 App 的私有源码目录。游戏运行数据、账号、prefix 与基础 runtime 在用户环境，仓库中保存来源、版本与哈希契约，并非真实用户数据。模块的逐项归属和源码入口见[地图](../projectMap.md)。

首装时本来要从上游取的三样东西——基础 Wine runtime 镜像、idv-login、网易下载核心——都由 Go 获取器负责。它们各自接受一个可选的「离线载荷」参数（`--payload-dmg` / `--payload` / `--payload-dir`），只在 App 的 `Contents/Resources/OfflinePayloads/` 存在时由 `productManager/` 与 `ToolboxViewModel` 传入；校验契约与联网路径完全相同，缺失或校验失败都 fail closed，不回退网络。要把这三样字节随包分发，用 [`offlinePackaging/`](../offlinePackaging/README.md) 的私有路径，**不要**给公开发行脚本加开关：那条路径的载荷审计刻意拒绝这些字节，两条策略互斥。

## 修改一处功能时

1. 先从界面所属 App 的 README 与 `Sources/` 找调用，再沿上面的模块关系定位实现；若跨两款 App，确认是明确共享的行为再放入 `sharedDiagnostics/`。先看对应测试与[工程取舍](engineeringDecisions.md)，避免只复制旧兼容分支。
2. 在当前用户游戏/App 未依赖的隔离工作副本中修改。根入口 `./devIterate.command launcher build`、`./devIterate.command toolbox build` 只生成候选；玩家启动器构建还会更新仓内 runner 模板、签名输入与可再生输出，不能在有运行中的同一路径候选时原地覆盖。`keyboard build` 仅构建键盘组件，不产生可安装 App。需构建工具以各脚本的实际前置为准；主要使用 macOS SDK/Xcode 命令行工具，玩家构建还调用 Go 与若干本仓检查。
3. 优先跑改动模块自己的合约测试，再对受影响 App 做完整构建与签名树/部署目标检查。构建脚本会调用多项自检；通过只证明对应静态与候选条件。已授权的本机功能开发与修复随后默认继续更新日用版、重启实测和收尾。`./devIterate.command … run` 打开隔离候选，`… install` 构建并安装，`./installIdentityVApps.command` 安装已有构建并备份旧 App；根据已经核验的产物选择入口，不为安装已有合格产物重复构建。

   安装前确认当前日用路径、旧进程及游戏/下载占用，正常退出旧 App，用安装器更新同一日用位置，再从该位置打开；核对实际运行路径与构建身份，并操作验证本次修复。存在不宜中断的对局或下载时，先完成其他准备，记录具体等待条件和接续方式。失败则保留必要现场、修复后重验或恢复已知可用版，不把未通过候选留作日用交付。只读调查、迁仓/文档整理、明确只要候选或隔离实验的任务按其范围执行；首装隔离实验与日用更新分别管理，不让同身份副本同时争用用户数据。目的和历史依据见[本机开发交付闭环](engineeringDecisions.md#本机开发交付闭环)。

4. 若更改 App/runner 内容或签名输入，发行候选需从干净的确切源码提交重建、签名、公证并重算对应源码与材料哈希。构建把提交、构建前干净状态、发行号与实际默认 runtime 写入 App 的 `build-provenance.json`；封包器逐项核对并拒绝已公开的同名版本。纯文档整理不回写已签 App。版本及对用户的变化同步[变更记录](../CHANGELOG.md)，原因、失败路径和适用边界留在相关测试、代码注释或工程说明。结构、入口或脚本效果改变时，同步[项目地图](../projectMap.md)；普通函数细节不必改地图。

### 更新与首装测试的空间收尾

大型构建/缓存可以用独立外盘目录；运行环境的真实APFS映像测试会单独使用系统临时挂载目录，并由Go测试清理。2026-10-04在macOS27.2上，将TMPDIR设在外盘导致只读attach“权限被拒绝”，相同测试改回系统临时目录通过；因此测试仅把小型挂载目标放回系统临时区，映像来源和编译缓存仍可在外盘。这个环境差异不修改产品安装目的地，不用跳过映像校验或申请系统权限来掩盖失败。

登录下载器的真实离线映像测试同样受该挂载限制；其小型合成映像、挂载点和临时状态使用独立系统临时目录并自动清理，Go编译缓存仍可在外盘。不同测试包原先采用各自临时目录策略，因此完整构建才暴露第二处限制；不把早先运行环境测试通过当成其他包也已经完成。

音频模块隔离构建归属`wineAudioPatch/`。`stageDefaultDeviceRuntime.command`要求显式给出已核验audio1来源、模块、bootstrap及不存在的新目标目录；只克隆运行包、对新模块做本地ad-hoc签名、生成候选manifest/catalog并完整复验。不触碰prefix/current链接，也不启动Wine；派生catalog候选不成为产品默认。它不是公开封包器，发行签名、许可闭包与实机输入输出切换仍须独立完成。

普通 App 更新只替换 `/Applications` 中的 App；现有游戏目录、Wine runtime、prefix 和账号状态各在 App 外，构建或安装新版 App 时不复制游戏。安装脚本为失败回滚保留旧 App，待新版完成本轮实际验收后，在同一任务中核对当前 App、所需回退版本与备份目录，移除过期 App 备份及构建/封包中间目录。未验收的候选保持隔离并注明归属，不把每日巡检当作正常收尾步骤。

本机开发版按所有者2026-11-05补充要求：成功验收后不保留旧App回退副本，需要时从保留源码与材料重建。安装器同次事务产生的临时旧App在验证完成后移到废纸篓，不永久删除、不处理其他备份或游戏/配置。

完整首装或卸载实验若需隔离旧游戏，旧游戏整树只作测试期间的临时副本。先单独保存无法重新下载的设置、键位、账号和诊断证据；确认活动游戏已由下载器重新建立且本轮不再需要旧状态时，立即删除旧游戏整树，并更新私人恢复点记录。游戏资源可重新下载，不能为了可能的快速回滚无限期保留十几 GB 的整树；只有当前实验确实要比较旧资源字节时才明确保留，并在实验结束时重新判断。每日空间巡检只报告遗漏的过期产物，不决定版本验收，也不自动删除活动运行数据。

## 入口和兼容边界

材料生成器可通过`IDENTITYV_NOTICES_CACHE_ROOT`只读复用调用者已有的原厂源码归档/许可文本，每个命中仍按manifest校验普通文件、大小和SHA；损坏会失败，不改缓存原件。首方源码不走缓存，始终从clean HEAD生成。大缓存放已核验外部卷，保留与清理由调用者负责，详见[材料说明](../notices/README.md)。

许可材料生成器与封包器共同读取`IDENTITYV_NOTICES_BUILD_ROOT`（绝对路径）；未设置时沿用`notices/.build`。大源码归档、材料stage及最终`ReleaseMaterials`可放独立外部构建目录，避免在系统盘保留可再生缓存。调用者先核对外部卷身份和挂载，再同时向两个脚本传同一值；脚本只验证绝对路径，不替代卷UUID检查。RC2材料同时收纳实际GDI/音频补丁、构建配方与回归源码，不能仅沿用RC1 ClipCursor来源说明。生成器要求clean checkpoint并收纳该HEAD的首方源码归档/commit文本；最终App构建身份必须匹配，源码链接不能只指向移动的main。

日常开发用 `devIterate.command`；独立构建用 `buildPlayerLauncher.command`、`buildMaintenanceToolbox.command` 和由玩家构建调用的 `buildGameRunner.command`。封包器 `releasePackaging/buildAlpha1Preview.command` **仍是现役脚本**，其中 `Alpha1` 只是保留的历史文件名，实际版本取 App 元数据，不应用文件名推断版本。旧独立 runner 安装器和退役浮窗入口已退出仓库根目录；缘由及恢复旧实现的方法见[历史命令](legacyCommands.md)。其余根脚本的读/写、安装、提权和服务影响以[地图的命令表](../projectMap.md#根目录文件构建与开发入口)为准，不要把 `*.command` 当作说明文档双击。

第一方 bundle ID、Developer ID 签名、TCC、Keychain service/account 与用户运行数据目录分别是兼容契约。改源码目录名不自动迁移它们；需要改变身份时按[身份方案](firstPartyIdentity.md)核旧数据与恢复。已有本地候选不等于可公开发布：公开前还要审查拟推 Git refs、隐私、许可证、最终包和真实安装/游戏结果。

### 自定义安装与已有目录检测（RC5）

游戏地址行右侧的「自定义游戏位置」复用页面其他操作按钮的 capsule/large 控件。选择器接受文件或目录：文件取所在目录（包括 dwrg.exe 和其他文件），目录取本身；共享管理核心检查该目录及 game/DWRG/IdentityV 子目录中可读取、带 MZ 头的 dwrg.exe。检测存在不代表服务器或完整性已确认。找到新位置后按所选服的官方基础清单只读检测并登记；基础清单不符仍可登记，状态明确标为完整性待确认，不修复或覆盖热更新。选择已登记的同一位置仅刷新状态（prefix 缺失仍保留受管所有权，并继续显示需要修复），保留所有权和兼容环境。

未找到时显示「当前位置没有找到第五人格，是否安装」及实际 game 子目录目标；「好的」进入正常安装，「取消」不创建目录、不变更记录。默认目录初次不存在仍交给管理器完成 RC1 迁移与创建，避免 GUI 提前制造迁移冲突。安装目标可有无关兄弟文件，受保护的 game/.staging/work 事务目录不覆盖。外部导入保留 externalGameRoot 语义，卸载不删除原游戏文件，修复不降级覆盖它。

共享接口 `IdentityVProductManager resolve-location --json --product mainland|global --path <现存文件或目录>` 为只读、离线位置解析，返回 schemaVersion、productId、selectedPath、selectionKind、installDirectory、found、可选 gameRoot 和 alreadyRegistered；只解析位置，不下载清单、不创建目录。`inspect --json --product … --path <直接含 dwrg.exe 的目录>` 执行官方基础清单 XXH64 校验；检测范围不包含全部热更新、账号或登录状态。Agent 调用同一核心，见 [CLI契约](agentCLI.md)。文件/目录、其他文件父目录、无游戏、坏头、另一服与同路径绑定、缺失位置及 sentinel 不变更均纳入管理器自检；GUI 选择取消、安装确认和最终三语言布局由整体验收验证。


### macOS 14 与部署目标审计

第一方 App 的构建通过不涵盖首次下载的 runtime；完整槽须用 `runtimeManifest/auditMachODeploymentTargets.command` 单独扫描。该命令解析输入根的符号链接并拒绝零文件，symlink/empty-root 回归已纳入玩家 App 构建。当前 DXMT Unixlib 仍为 macOS15，因此不能仅修改 Info.plist 或 runtime minimumMacOS 来宣称14支持。独立重建与VM/真实GPU验收矩阵见 [DXMT兼容专题](../runtimeManifest/dxmt080MacOS14Compatibility.md)。

### Agent 与自动化入口

`productManager/AgentCLI.swift` 为同一 ProductManager 可执行文件的 `agent` 子命令，管理任务记录/事件/输出并重新进入原核心操作；不另写安装器。`productManager/agentSelfTest.command` 用无副作用 fixture 验证运输层。完整构建编译新源码；CI workflow 保留在独立候选，因权限阻碍未纳入本轮接口整合，不发布 App。操作示例、真实日志/历史诊断区别及未接入能力看[CLI契约](agentCLI.md)，runner资源与协作流程看[CI调查](ciWorkflow.md)。集成时先核对本轮候选分支与并行 RC5 文件改动，禁止直接覆盖他人源码或正本记录。

RC5交付必须同时包含Agent接口和本版文档；完整构建将`docs/agentCLI.md`放入App Resources的`agent-cli.md`，`agent help`给出实际路径/可读性，`agent docs`直接返回Markdown文本。以后新增业务功能同步接口/状态/错误/文档及验证，遵循AGENTS的新规范。CI工作流调整单独推进，不把首次远端CI配置列为RC5的额外发布门。

首次托管CI试验可用临时ci/**分支push自动触发，无需预注册workflow_dispatch或持久runner；具体远端操作先报告。模块`productManager/selfTest.command --network-smoke`会在默认离线合约后，经同一核心请求两服官方安装器地址的小型元数据，不下载载荷；不带该选项仍不请求官方网络。初次检查只读API确认Actions已启用、默认token只读，尚未实际推送/运行托管job。

IDV Login 的固定清单用于下载校验；安装状态、可选版本更新和 helper 修复独立判断。状态工具启动准备会移除历史项目禁更新记录，保留其他上游记录，见[来源审计](idvLoginSourceAudit.md#取消强制更新与历史更新阻断2026-11-05)。

玩家帮助菜单可读取随包 Agent 文档和复制 `Contents/Resources/idv help` 命令；`productManager/idv` 由玩家构建按755复制。它只添加 agent 前缀，不执行全局安装。删除确认展示核心预检的真实游戏位置及删除项，核心在修改锁内验证预览指纹后才停止进程/删除，避免确认期间绑定变化。CLI和GUI共用位置解析；更改这些契约时同时跑管理器与Agent自检。

反馈视图的讨论组页与三语README共用FeedbackDestination常量，diagnostics的目标自检核对三份README；发送只打开邮件草稿，讨论页不替用户发送邮件。QQ提示气泡/收起及邮件前台切换需在最终包检查；社区链接为公开目的地，不将测试点击当作加入群组。

### 运行器会话发布回归

`gameRunnerApp/tests/sessionPublication.test.command`由玩家构建执行，也可单独用zsh运行；只编译/运行无GUI的arm64与x86_64探针及空dylib，需要已有Rosetta，不安装兼容组件，不运行Wine或游戏。它验证Wine子进程注入边界、保持PID/fallback以及固定字段会话的0600原子发布和失败保护；机制与真实来宾边界见[RUN-SESSION](windowAndLoginInvestigation.md#run-session来宾游戏已存在但启动确认失败2026-11-05)。

IDV Login「打开后台」和 `idv run login-admin-open` 共享 `LauncherUpdateAgent.swift` 中 LoginAdmin，复用 ToolboxViewModel 的只读 readiness gate。`playerLauncherApp/Tests/loginAdminSelfTest.command` 验证打开/拒绝/浏览器失败，不操作真实组件；完整玩家构建执行该检查。地址与安全边界见[来源审计](idvLoginSourceAudit.md#rc5-管理后台入口2026-11-05)。
