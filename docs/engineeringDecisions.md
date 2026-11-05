# 工程边界与验证依据

本文记录产品源码树的关键取舍及分阶段验证；各节中的「当前」「候选」「尚未」均以该节所述时间和构建为准，最新交付及验收状态以 [STATUS](../STATUS.md) 为准。快速接手从[开发者指南](developerGuide.md)进入，版本变化看[变更记录](../CHANGELOG.md)，已退役操作入口看[历史命令](legacyCommands.md)。本页是公开可读的工程说明；个人账号、原始诊断、截图和本机运行记录保存在私人项目档案，不是阅读本仓的前置条件。

## 一个仓、两个 App

`第五人格启动器.app` 面向玩家，负责游戏下载、校验、启动、修复、卸载与反馈；`第五人格工具箱.app` 面向维护者，负责性能浮窗与按需采集。它们需要相同的游戏健康、资源采样和采集生命周期契约，所以代码同仓，构建与安装目标仍分开。游戏 runner 在启动器内嵌，不能把 `gameRunnerApp/` 当成另一个供玩家单独安装的桌面产品。

旧源码目录名曾使 `toolboxApp/` 指向玩家启动器、`monitorApp/` 指向维护者工具箱。独立仓以 `playerLauncherApp/`、`maintenanceToolboxApp/`、`gameRunnerApp/` 明确归属。`DenseMonitoring.swift` 被两款 App 编译，现归 `sharedDiagnostics/`；构建脚本显式列入共享源码，避免工具箱跨入玩家 App 的私有目录。构建和安装的对人入口分别用 `buildPlayerLauncher.command`、`buildMaintenanceToolbox.command`、`buildGameRunner.command` 与 `installIdentityVApps.command`，`devIterate.command` 仍按 `launcher`、`toolbox` 区分目标。

## 运行环境与分发输入

游戏、基础 Wine runtime、网易下载核心和可选 `idv-login` 不随玩家 App 打包；相关下载或组件按清单指定来源、版本和哈希，安装在用户环境。`runtimeBootstrap/releasePayloads/` 的四枚已签名 Wine 补丁是当前 App 构建所需的精确字节，因而纳入本仓而非依赖旧本机目录。`runtime-manifest.json` 的 `sha256` 校验分发字节，`sourceSha256` 对应签名前的来源字节；重新签名会改变前者，不可在构建时暗换。签名补丁与 runner 模板中的预编译输入不等于人写的源代码，相关来源、对应源码与许可证见[运行环境说明](../runtimeBootstrap/README.md)及[第三方材料](../notices/README.md)。

新仓从审查过的当前源码建立首个提交，后续正常开发在这里提交。旧私人仓的历史和原始现场另行保留，不导入未来可能公开的产品提交链；有价值的根因与适用条件在本仓用脱敏说明和测试表达。公开前仍须审查所有拟推 refs 可达的旧版本和元数据；凭据扫描只是辅助，不能证明没有个人信息。

这项选择在 2026-09-23 的独立仓基线中解决了一个具体复建问题：旧私人工作树把四枚**已签名** runtime 替换文件放在忽略目录，单凭原源码清单复建会缺失精确输入。新仓把这四枚已核来源与 SHA-256 的文件作为受控构建输入纳入版本管理，manifest 同时保存签名前来源哈希和当前分发哈希；[材料入口](../notices/README.md)给出对应源码与构建说明。这样可从干净克隆复建候选，但不能由“可复建”推论基础 CodeWeavers/Wine 闭包已有本项目再分发权。2026-09-23 的 RC1 方案由用户从锁定的上游地址取得基础 runtime；若改为本项目镜像，完整闭包 BOM、许可和源码审查需要另做。

## 本机开发交付闭环

2026-11-05 明确：已授权的本机开发与修复，以日常入口实际运行并验证新版为交付条件，默认连续完成修改、必要检查、完整构建、更新日用 App、正常重启、实测及收尾。构建器保持只生成产物的职责，协调执行者负责衔接安装和验证；这样既避免任意中间构建覆盖正在使用的程序，也避免把候选构建成功误当用户已经用上新版。

原有“除非任务明确要求，不因源码变更更新已安装 App”的表述自 2026-09-23 独立仓首提交存在。当时迁仓任务限定不改变日用安装与活动游戏，该限制适合迁仓范围，却不能作为所有功能开发的默认停止条件。本次收窄到只读调查、迁仓/文档整理、明确只要候选或明确隔离的实验；当前明确任务范围优先，既有安装与测试授权不因步骤切换失效。

更新前核对日用路径及对局、下载等占用，必要时保留有明确接续方式的安全停点；通过必要检查的完整产物由安装器更新同一日用位置，保留必要回退，再核对运行路径、构建身份和相关实际功能。App、runtime、游戏进程与系统权限各按真实影响判断，不用笼统保护限制替代现场核对。公开发版另按该任务的授权和最终发行验证执行；日常迭代不必每次重复完整发行公证流程，仍须满足本机运行所需的签名与权限条件。

## 签名、安装与验证的界限

目录和脚本名的可读性更改本身不改变 bundle ID、TCC/Keychain 身份、用户安装数据目录或兼容协议；这些是既有安装的身份与恢复契约。公开前第一方身份另按[具体迁移方案](firstPartyIdentity.md)调整，同时保留旧数据路径和必要兼容引用。构建脚本仅生成候选；`devIterate.command ... run` 会打开候选，`... install` 和 `installIdentityVApps.command` 才更新 `/Applications`。对 App 内脚本、资源或签名输入的修改须重建、签名并视发行目标重新公证。只有仓外文档或路径的改变不会追溯改变已签 DMG 的字节，但对应源码包与哈希仍须重算。

静态测试、两款 App 构建、签名树和 Gatekeeper 验证各覆盖不同条件；它们不代替干净 macOS 首次安装、授权提示、真实对局及国际服登录保持。当前 1.0.0-rc.1 仍是发布前候选，最终发行审查与公开上传是后续独立步骤。

`1.0.0-rc.1` 是 2026-09-09 选定的候选**版本名**，不是此后每轮相同版本号字节的功能验收。2026-09-23 新身份候选完成签名、公证与本机旧装升级，并由安装版内嵌 runner 进入国服大厅。初次游戏内语音发送报未检测到声音；后来从日用启动器正常启动、同一游戏会话里，合盖仍失败，开盖后可录入。引擎选择的是 MacBook Pro 内建麦克风，Apple [硬件安全说明](https://support.apple.com/en-au/guide/security/secbbd20b00b/web)明确 Apple silicon MacBook 合盖会断开内建麦克风，这解释了本次差异，不需要据无新弹窗重置 TCC。双服 GUI 之前漏走麦克风权限前置检查，已在候选源码补上；它是独立的首次授权路径修复，不是合盖无声的根因。

同一局较早时内建键盘 F 区曾有效，Rainy 75 外接键盘 F11 与 Fn+F11 均触发系统音量提示；稍后风吟重测，内建也与 Rainy 一样失效。watcher 较早的标准 F 行租约日志只能证实中间状态，不能证明她实际按键时仍持有租约。风吟又换一把外接键盘：F1–F9 单按被游戏捕获，F10/F12 触发系统音量 HUD、F11 显示桌面；Fn+F10/F11/F12 得到无 HUD 的预期音量行为。这里无 HUD 路径是游戏进程经 CoreAudio 调**当前 macOS 默认输出设备**，不是独立游戏音量；有 HUD 通常是系统媒体键处理路径。对应时段 runner 多次记录 `mode change unavailable` 并撤回租约。因此不能把当时所有按键异常只归因于 Rainy 固件，也不能说整个外接 F 区失效。正常结束游戏后，同一四键盘服务集合的短时探针成功写入并恢复租约，推翻“当前接口静态永久拒写”。诊断候选在新会话里多次成功建立租约，四服务均有映射，风吟确认内建键盘恢复；此前运行中失败的条件仍未知，诊断日志的增加本身不是功能修复。

Rainy 在该新会话的 Mac 模式下仍有 F1–F9 行为异常；F11 和 Fn+F11 都表现为音量减，风吟认为 F10–F12 已按预期。短时、仅针对 Rainy 的 HID 白名单采样实际看到标准键页 F10–F12 与消费页静音/音量加减两类事件，但风吟在采样窗口内测试了整排键，记录没有逐事件时间和接口，不能证明哪一个物理键产生哪一条事件。Rainy [厂商手册](https://drivers.sfo3.digitaloceanspaces.com/Rainy_75_EN.pdf)列 Mac 模式的多个 F1–F9 基础键为亮度、任务视图或媒体功能，并允许用 Fn+M 在 Mac/Windows 模式间切换。风吟在**同一局**短暂切到 Windows 模式，单按 F1 和 F5 均正常进入游戏；她同时指出 Command 落到物理 Win 键，说明这不是无代价的日用方案，也不等于 F1–F9 全部逐键通过。既有[键盘转发器](../wineKeyboardPatch/IdentityVCommandGraveForwarder.m)的 2026-09-18 实测表明：本机媒体顶排输入在系统消费阶段被截走，连 session event tap 都无法观察；现行 [F 键控制器](../functionKeyController/IdentityVFunctionKeyController.swift)只管理全局标准 F 行与键盘页 F11→F20 租约，不能把 Rainy 固件直接发出的消费页输入改成 F1–F9。若保持 Mac 模式又要求单按整排键自动进游戏，需要另评估设备层 VIA 键位配置或更低层的权限/拦截架构，不能在未证明输入路径前叠加全局按键监听。反复切窗这轮没有爆音；原先声学异常仍是一次真实反馈，目前既未重现，也没有根因修复。用户可见的当前状态集中在[变更记录](../CHANGELOG.md)，身份升级的已证实范围和兼容理由在[第一方身份说明](firstPartyIdentity.md)；原始私人现场不作为公开文档的必读前置。


## GitHub Releases 手动版本检测（2026-11-05）

`ToolboxViewModel.checkForLauncherUpdate()` 原来只显示当前版本与手动替换说明。现有“版本与更新”按钮接入 `LauncherUpdateChecker`，只有用户点击时异步读取公开 Releases；不在启动时检查、不写用户设置。只有用户明确点击“更新”后才下载、校验并安装对应 macOS 资产。安装版版本优先取 `IdentityVReleaseVersion`，再取 `CFBundleShortVersionString`；build number 不用于公开版本比较。更新检查的状态只控制该按钮的重复请求，不参与游戏或组件的任何可用性条件。

2026-11-05 直接匿名读取[项目 Releases API](https://api.github.com/repos/FengYinYH/IdentityV-Launcher/releases)，得到 `v1.0.0-rc.4`、`rc.3`、`rc.2`、`rc.1`，全部 `draft=false`、`prerelease=true`，每版都有对应 DMG；同一时刻 `/releases/latest` 返回 404。网页搜索缓存仍只显示 RC3，不能拿缓存页面决定最新版本。[GitHub 文档](https://docs.github.com/en/rest/releases/releases)说明 latest 不包含预发布和草稿，Releases 列表不包含只有 tag 而未建立 Release 的版本。因此使用 Releases 列表，不依赖 latest、数组第一项或发布日期。

所有者明确本阶段不区分稳定与测试渠道：所有已发布、非草稿且 tag 符合 SemVer 的 Release 参与比较，API prerelease 标记不作为筛选条件。去除约定的前导 `v` 后按 SemVer 数字段与预发布标识比较（`rc.10 > rc.9`、`1.0.0 > 1.0.0-rc.5`）；构建元数据不影响优先级，同版重新发布不提示更新。数字用长度及字典序比较，避免整型溢出。未发布、草稿或非法 tag 被忽略。

每页 100 条，最多 10 页；固定构造本仓 API 分页地址，不跟随响应 Link 中的任意地址。按 next 标记或满页继续，完整取得分页后才选最大版本；后页失败、超出上限或响应无效都显示检测失败，不能把局部结果宣称为最新。单次请求 15 秒超时，URLSession 资源超时 20 秒。Actor 串行维护单飞、限流与缓存，网络等待不占用主线程。

[匿名 API 限流](https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api)为共享出口 IP 每小时 60 次。完整成功结果在进程内复用 60 秒，失败后至少等待 60 秒再请求。每页保存 ETag、完整成功正文与后页标记；下次发送条件请求，304 只可读取匹配缓存。缓存仅在完整遍历成功时整体替换；后页失败不提交前页数据，也不把旧成功结果当本轮成功。缓存不跨进程保存，不写 UserDefaults 或磁盘。官方免计主限额的保证针对已认证条件请求，匿名请求不能假定免费。[官方退避建议](https://docs.github.com/en/rest/using-the-rest-api/best-practices-for-using-the-rest-api)用于 403/429：至少 60 秒，并取 Retry-After（秒数或 HTTP 日期）与额度耗尽时 X-RateLimit-Reset 中最晚时间；不自动重试。

结果交互使用项目图标：无更新时显示“已经是最新版”和“好的”；有更新时第一行“已检测到新版本，是否更新？”，正文两行“当前版本：xx”“最新版本：xx”，左侧取消、右侧蓝色默认主按钮“更新”（primary action / default action）。不跳转发布页。网络失败、404、解析失败或不完整列表显示暂时无法检查；空列表单独提示没有可用发布。检测及失败均不阻止启动、卸载、停止或跟随启动。

### 用户确认后的 macOS 更新事务

`LauncherUpdateInstallation.swift` 的共享准备与事务核心供 GUI、显式 App Agent 后端及独立签名的 `UpdateHelper/LauncherUpdateHelper.swift` 使用。下载只接受该 Release 唯一的 `IdentityV-Launcher-<版本>.dmg`，要求 uploaded、1 GiB 内正数大小、GitHub SHA-256 digest 和本仓固定 HTTPS 地址。URLSession 落临时文件，超出声明大小即取消，30 秒请求和30分钟资源时限；以文件流复算摘要后只读挂载，不运行映像中的脚本。

App 的 Bundle ID、精确发行号、约定入口和当前架构须匹配；全局或当前架构的最低 macOS 要求不得高于本机。`codesign --verify --deep --strict -R =<requirement>` 固定 Apple 信任链、Developer ID Application 及 Team `VNTCB2984V`，准备阶段另作 Gatekeeper assessment。当前 App 也须通过项目身份与 Gatekeeper；开发 ad-hoc 包没有生产更新绕过开关。仅替换当前系统/用户“应用程序”中的固定同址 App，要求当前用户所有、无符号链接、父目录可写，不提权、不借游戏 helper 安装任意 App。

每次在confstr实际用户临时区创建私有0700 UUID事务根，不随CLI的TMPDIR变化，保证LaunchServices启动的新GUI能验证同一回执路径；先写恢复计划，再下载、挂载、复制到目标同卷的唯一 stage 并再次验签。清理不依赖 attach 的返回值标记：即使命令失败或超时，也读取实际 hdiutil 挂载清单，仅卸载本事务约定的 Mount；未知挂载、清单不可读、卸载失败均保留目录，不递归清理仍挂载的树。成功或安全失败仅直接清除本次私有根与自己创建的 stage，不扫描 Downloads 或其他事务。取消准备但清理失败会报告失败和保留位置，不把它包装成完整回滚。

系统校验命令经 posix_spawn 建立独立进程组，输出落私有普通文件，避免后代持有pipe造成EOF阻塞；超时先TERM、0.5秒后KILL本组，并等待确切子PID，8 MiB输出上限同样收束。升级状态不保证断电、强杀后的自动清理，保留计划可用于人工恢复。

`sharedDiagnostics/LauncherOperationLocks.swift` 实现活文件描述符 lease，检查UID、普通文件、单链接、私有权限并拒绝symlink。admission按实际用户临时区与App canonical路径建立，不随业务HOME变化，隔离HOME的同址任务也保护相同资源；助手用计划target定位，独立App副本互不抢占。普通Agent worker和直接ProductManager业务入口持共享 admission lease；后者覆盖inspect/resolve等只读业务，不写游戏或安装记录，但允许内部锁 bookkeeping。更新install worker自身不持此共享lease。助手先取得本事务 helper.lock，再独占admission、既有product-manager.lock及目标安装锁，持有至回执/回退结束。因此旧任务阻挡替换，新任务也不能在检查后抢入；不凭陈旧task.json或PID猜任务是否活着。既有GUI变更复用同一个product-manager.lock。GUI还检查产品/组件/下载忙状态，游戏与旧独立组件活动在替换前再次核查，不强停游戏。

助手在锁内重新检查原版本和build、暂存项目签名及新版本必须较新，避免两个已准备任务对旧状态连续成功。ready只表示验签与取锁完成；调用方另写绑定token的commit，再正常退出旧GUI。CLI可列举同址GUI并正常请求退出，自己继续等待助手结果。助手等待计划中的旧PID退出后同卷rename旧App到backup、新App到原址；校验/移动失败恢复旧App。启动新版使用保留的 `--launcher-update-receipt <事务根>`，它经默认SwiftUI入口进入主界面，不能被CLI截获；只有显式 `--launcher-agent-operation` 才进入Agent后端，Resources/idv仍是独立短入口。

主界面onAppear立即写入token、PID、安装路径及版本回执，助手同时核对实际新进程；回执不等待状态扫描。新GUI初次扫描可能被助手独占锁拒绝，因此只在更新启动后做一次有界等待lease释放再重读状态，避免永久留下busy，也不新增常规磁盘轮询。确认后才清除旧备份和本次DMG/事务，CLI任务也须等实际退出结果并验证installed与cleanupComplete才成功，不能把ready或helper已启动当完成。新进程仍在但无回执时保留新旧App及计划，绝不在活进程下面移动资源；新进程未启动或已退出才回退重开旧版。已确认新版但清理失败同样报告失败且保留恢复信息，不在活新版下回退。回执仅证明主界面出现，不代表游戏完整回归。schema1计划/回执是首次引入的兼容契约；旧公开RC4无此协议，不能作为真实重启回执验收的替身。

### 独立整合候选的验证与边界（历史快照）

检测单测覆盖SemVer/RC排序、草稿和未发布、分页/不完整响应、ETag/304、限流、缓存和并发。隔离安装测试使用假App真实rename验证成功/签名拒绝回退、stage缺失、已有backup保护；另测回执身份与显式入口路由、最低系统版本、旧版本/build变化拒绝、共享/独占lease、symlink锁拒绝、部分挂载/未知挂载/卸载失败保留、忽略TERM时的有界收束，以及ready/commit分离。没有替换日用App、真实挂载或对新候选作Gatekeeper正向验收。

真实Agent运输层加Python mock GUI覆盖任务UUID传递、活lease阻挡、等待确认、早取消、晚取消后等待实际成功结果；mock不显示原生窗口、不冒充实际签名更新。GUI全源码类型检查通过，既存卡死提示Timer actor警告仍保留。管理器完整自检及原接口回归通过。正式签名整包、真实下载/同址替换/新GUI回执/成功清理仍须独立验收。

所有者暂停KVM输入期间，`agentSelfTest.command --headless`或构建环境`IDENTITYV_TEST_HEADLESS=1`仅推迟Python测试中的原生删除确认框段，并明确打印DEFERRED；运输、日志、协议及取消测试照跑。默认仍运行原生段，生产AgentCLI不读取测试flag、没有确认绕过。当前原生更新确认、GUI交互与真实日用替换均未在此候选执行。


### 更新结果的物理状态与协议状态

助手的所有成功/失败输出均给出`targetState`与三态`targetReplaced`、`startupConfirmed`、`recoveryRequired`和`cleanupComplete`。兼容字段installed仅是startupConfirmed别名，绝不是磁盘状态。实际swap返回成功立即记replacement；活新版无回执仍保留这个true，另外标记未确认启动及需要恢复。回执通过但清理失败保持replacement/confirmed并要求收尾。回退之后再验证旧项目签名、发行号和build，才能记original/false；回退或验证失败记unknown/null并保留恢复信息。初期未验证目标或无效调用也不猜磁盘状态。

需要手动恢复/收尾时返回已知target与事务根，backupPath仅在备份实际存在时输出，不承诺已删备份可用。状态单测覆盖预替换失败、活新App无回执、确认后清理失败、已验证回退、回退不确定及成功结果；它验证共享状态投影，不是实际NSWorkspace启动/故障验收。原有假App rename/回退检查仍运行，本补充未替换任何真实App或显示窗口。

### build20 实际签名副本事务验收

无GUI隔离测试将实际项目Developer ID签名的旧/新App副本交给生产swap/rollback/verifyApp：新目标与旧备份签名及构建身份正确；显式回退恢复旧版；新副本在移动后验签失败时恢复旧版并再次验签通过。此测试没有调用完整helper、启动新GUI、合成新版Release或绕过路径/版本准入，不代表更新全链成功。本地未公证包的实际Gatekeeper评估为Unnotarized Developer ID拒绝，生产准备阶段会拒绝它，保留该行为。完整准入/下载/回执仍待合格发行包及独立测试。
