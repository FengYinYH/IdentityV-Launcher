# 开发者指南：项目框架与维护入口

这是已有 macOS 开发基础的维护者接手本仓时的路径。玩家的安装与使用看[项目首页](../README.md)；逐个顶层对象及脚本副作用看[项目地图](../projectMap.md)。本页说明模块如何协作、从哪里改、如何验证，不重复目录清单。关键取舍与兼容原因在[工程边界](engineeringDecisions.md)和[第一方身份迁移](firstPartyIdentity.md)；发行材料与签名分别有[封包](../releasePackaging/README.md)、[签名](../signing/README.md)说明。

## 运行与构建关系

本轮候选的语言和来源维护见[语言说明](launcherLocalization.md)、[IDV Login 来源与固定更新策略](idvLoginSourceAudit.md)。登录策略通过原生状态工具生成受管 overlay，helper 合约为 8；升级组件时必须复核冻结模块加载和策略版本门，不能只更改 asset manifest。

IDV Login 版本升级须同步清单、Swift UI/cache 常量、Go 下载器精确字节锁和许可来源；当前 6.3.1 上游标签是 beta，不能推断有 stable 资产。通常先退出游戏再运行安装器。已明确安排保留活动游戏的维护更新，可先停止登录代理，再使用安装器的 `--allow-running-game-with-stopped-proxy`；此参数仍要求代理进程和托管 hosts 均已消失，不提供活动代理绕过。具体证据与回退见[组件说明](../idvLoginComponent/README.md)。

玩家 App 的界面和调度位于 `playerLauncherApp/Sources/`。下载与校验依次由 `productCatalog/`、`productManager/`、`manifestPlanner/`、`gameDownloader/` 等模块负责；国服和国际服首装及完整性修复共用 manifest planner 与网易 `downloadIPC.exe` supervisor，国际服通过显式 `oversea` 路由保持 LoadingBay 产品身份。国际服 adapter 仍独立解析并校验官方清单及安装器地址；两服的发布事务和游戏路径绑定保持分开。共链证据及边界见[网易下载核心共链说明](downloadCoreUnification.md)。共享 Wine/DXMT 输入由 `runtimeManifest/` 与 `runtimeBootstrap/` 锁定、取得和核验。玩家点启动游戏后，内嵌的 `gameRunnerApp/IdentityV-Mac.app` 承接启动命令，调用 Wine，再进入游戏。`gameRunnerApp/IdentityV-AGTK.app` 是历史/开发模板，不在当前玩家 App 内出货。

维护者工具箱的 UI、浮窗和采集在 `maintenanceToolboxApp/Sources/`，独立构建与安装。两款 App 显式编译 `sharedDiagnostics/` 的健康、采样、采集状态和受限旧偏好迁移源码；工具箱不调用玩家 App 的私有源码目录。游戏运行数据、账号、prefix 与基础 runtime 在用户环境，仓库中保存来源、版本与哈希契约，并非真实用户数据。模块的逐项归属和源码入口见[地图](../projectMap.md)。

首装时本来要从上游取的三样东西——基础 Wine runtime 镜像、idv-login、网易下载核心——都由 Go 获取器负责。它们各自接受一个可选的「离线载荷」参数（`--payload-dmg` / `--payload` / `--payload-dir`），只在 App 的 `Contents/Resources/OfflinePayloads/` 存在时由 `productManager/` 与 `ToolboxViewModel` 传入；校验契约与联网路径完全相同，缺失或校验失败都 fail closed，不回退网络。要把这三样字节随包分发，用 [`offlinePackaging/`](../offlinePackaging/README.md) 的私有路径，**不要**给公开发行脚本加开关：那条路径的载荷审计刻意拒绝这些字节，两条策略互斥。

## 修改一处功能时

1. 先从界面所属 App 的 README 与 `Sources/` 找调用，再沿上面的模块关系定位实现；若跨两款 App，确认是明确共享的行为再放入 `sharedDiagnostics/`。先看对应测试与[工程取舍](engineeringDecisions.md)，避免只复制旧兼容分支。
2. 在当前用户游戏/App 未依赖的隔离工作副本中修改。根入口 `./devIterate.command launcher build`、`./devIterate.command toolbox build` 只生成候选；玩家启动器构建还会更新仓内 runner 模板、签名输入与可再生输出，不能在有运行中的同一路径候选时原地覆盖。`keyboard build` 仅构建键盘组件，不产生可安装 App。需构建工具以各脚本的实际前置为准；主要使用 macOS SDK/Xcode 命令行工具，玩家构建还调用 Go 与若干本仓检查。
3. 优先跑改动模块自己的合约测试，再对受影响 App 做完整构建与签名树/部署目标检查。构建脚本会调用多项自检；通过只证明对应静态与候选条件。`./devIterate.command … run` 会打开候选，`… install` 或 `./installIdentityVApps.command` 会替换 `/Applications` 并备份旧 App，这两步属于明确安排的真实运行/安装验收，不能和 `build` 混用。

4. 若更改 App/runner 内容或签名输入，发行候选需从干净的确切源码提交重建、签名、公证并重算对应源码与材料哈希。构建把提交、构建前干净状态、发行号与实际默认 runtime 写入 App 的 `build-provenance.json`；封包器逐项核对并拒绝已公开的同名版本。纯文档整理不回写已签 App。版本及对用户的变化同步[变更记录](../CHANGELOG.md)，原因、失败路径和适用边界留在相关测试、代码注释或工程说明。结构、入口或脚本效果改变时，同步[项目地图](../projectMap.md)；普通函数细节不必改地图。

### 更新与首装测试的空间收尾

大型构建/缓存可以用独立外盘目录；运行环境的真实APFS映像测试会单独使用系统临时挂载目录，并由Go测试清理。2026-10-04在macOS27.2上，将TMPDIR设在外盘导致只读attach“权限被拒绝”，相同测试改回系统临时目录通过；因此测试仅把小型挂载目标放回系统临时区，映像来源和编译缓存仍可在外盘。这个环境差异不修改产品安装目的地，不用跳过映像校验或申请系统权限来掩盖失败。

登录下载器的真实离线映像测试同样受该挂载限制；其小型合成映像、挂载点和临时状态使用独立系统临时目录并自动清理，Go编译缓存仍可在外盘。不同测试包原先采用各自临时目录策略，因此完整构建才暴露第二处限制；不把早先运行环境测试通过当成其他包也已经完成。

音频模块隔离构建归属`wineAudioPatch/`。`stageDefaultDeviceRuntime.command`要求显式给出已核验audio1来源、模块、bootstrap及不存在的新目标目录；只克隆运行包、对新模块做本地ad-hoc签名、生成候选manifest/catalog并完整复验。不触碰prefix/current链接，也不启动Wine；派生catalog候选不成为产品默认。它不是公开封包器，发行签名、许可闭包与实机输入输出切换仍须独立完成。

普通 App 更新只替换 `/Applications` 中的 App；现有游戏目录、Wine runtime、prefix 和账号状态各在 App 外，构建或安装新版 App 时不复制游戏。安装脚本为失败回滚保留旧 App，待新版完成本轮实际验收后，在同一任务中核对当前 App、所需回退版本与备份目录，移除过期 App 备份及构建/封包中间目录。未验收的候选保持隔离并注明归属，不把每日巡检当作正常收尾步骤。

完整首装或卸载实验若需隔离旧游戏，旧游戏整树只作测试期间的临时副本。先单独保存无法重新下载的设置、键位、账号和诊断证据；确认活动游戏已由下载器重新建立且本轮不再需要旧状态时，立即删除旧游戏整树，并更新私人恢复点记录。游戏资源可重新下载，不能为了可能的快速回滚无限期保留十几 GB 的整树；只有当前实验确实要比较旧资源字节时才明确保留，并在实验结束时重新判断。每日空间巡检只报告遗漏的过期产物，不决定版本验收，也不自动删除活动运行数据。

## 入口和兼容边界

材料生成器可通过`IDENTITYV_NOTICES_CACHE_ROOT`只读复用调用者已有的原厂源码归档/许可文本，每个命中仍按manifest校验普通文件、大小和SHA；损坏会失败，不改缓存原件。首方源码不走缓存，始终从clean HEAD生成。大缓存放已核验外部卷，保留与清理由调用者负责，详见[材料说明](../notices/README.md)。

许可材料生成器与封包器共同读取`IDENTITYV_NOTICES_BUILD_ROOT`（绝对路径）；未设置时沿用`notices/.build`。大源码归档、材料stage及最终`ReleaseMaterials`可放独立外部构建目录，避免在系统盘保留可再生缓存。调用者先核对外部卷身份和挂载，再同时向两个脚本传同一值；脚本只验证绝对路径，不替代卷UUID检查。RC2材料同时收纳实际GDI/音频补丁、构建配方与回归源码，不能仅沿用RC1 ClipCursor来源说明。生成器要求clean checkpoint并收纳该HEAD的首方源码归档/commit文本；最终App构建身份必须匹配，源码链接不能只指向移动的main。

日常开发用 `devIterate.command`；独立构建用 `buildPlayerLauncher.command`、`buildMaintenanceToolbox.command` 和由玩家构建调用的 `buildGameRunner.command`。封包器 `releasePackaging/buildAlpha1Preview.command` **仍是现役脚本**，其中 `Alpha1` 只是保留的历史文件名，实际版本取 App 元数据，不应用文件名推断版本。旧独立 runner 安装器和退役浮窗入口已退出仓库根目录；缘由及恢复旧实现的方法见[历史命令](legacyCommands.md)。其余根脚本的读/写、安装、提权和服务影响以[地图的命令表](../projectMap.md#根目录文件构建与开发入口)为准，不要把 `*.command` 当作说明文档双击。

第一方 bundle ID、Developer ID 签名、TCC、Keychain service/account 与用户运行数据目录分别是兼容契约。改源码目录名不自动迁移它们；需要改变身份时按[身份方案](firstPartyIdentity.md)核旧数据与恢复。已有本地候选不等于可公开发布：公开前还要审查拟推 Git refs、隐私、许可证、最终包和真实安装/游戏结果。
