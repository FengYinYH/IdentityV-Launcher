# 国服与国际服修复共用网易下载核心

本文记录启动器将国服、国际服首装与完整性修复接入同一下载链的依据与适用范围。结论基于上游 `KKeygen/idv-login` 的 `main` 提交 `6e5523e7933c0c28662b1af2a77e129b512423b6`；上游代码可从其公开仓库按该 SHA 复核。本仓 `downloaderCoreComponent.json` 锁定的核心来自提交 `9b1ff598da6cb9ae6a952a8978ccf88bc8b2ae5c`，其中 `downloadIPC.exe` 为 34,378,168 字节、SHA-256 `5c11d3188d271c1df88d36d98bb440437d29e8a41c88dfd38602ce3c60c56f82`。该摘要与本轮 main checkout 的 `binaries/downloadIPC.exe` 完全一致，因而本仓实际锁定的核心就是已审查 main 所带的二进制。对二进制只做了静态字符串检查，可见 `oversea`、`isOverSea`、`LoadingBayAppPath`、`getLoadingBayHost`、`GlobalIsOversea` 与 `overseaUpdateServerURL` 等海外路由相关标记；没有运行它。

## 登录插件不是下载依赖

`downloaderCoreComponent.json`标识`netease-download-core`，与可选的`idvLoginComponent.json`分别锁定、分别获取。`IdentityVProductManager.runSharedDownloadCore`直接调用`IdentityVDownloaderCoreBootstrap`，安装到用户状态目录的`Components/netease-download-core`，再将三个核心文件准备到本服私有Wine prefix并调用监督器；该路径不调用登录程序、登录安装器、受管helper或登录readiness。管理器的国服首装、国服修复及国际服共链入口均采用该路径。

下载核心是网易提供的程序，不是IDV Login作者重新编写的下载引擎；当前获取位置是作者仓库中按提交与字节锁定的镜像。取用这个二进制不等于安装或运行IDV Login。独立bootstrap的本地HTTP/hash测试、管理器临时prefix核心复制/修复清单/清理测试都不准备登录插件；这些证明组件及准备链独立，不能代替真实服务和不透明核心的完整游戏下载实测。

## 网易官方原始载荷核验（2026-10-05）

实际请求[官方 Windows 下载 resolver](https://api.loadingbay.com/app/v1/download_client/windows/mkt-h55-official/url)，得到 302 到[网易 CDN 安装器](https://a50.gdl.easebar.com/7497956734284075008/Identity_V_setup.exe)。安装器为 147,731,528 字节，SHA-256 `508c96dd4320a40da830d3f75fca5c95eacf60e05e74794738c0f57c23bd368a`；其 Inno Setup 数据版本为 6.4.3，产品标识 LoadingBay 1.5.26.11。

安装器没有执行。现成 innoextract 1.9 仅支持至 Inno 6.0.5，解析失败属于工具版本限制；随后从上游源码构建并审阅 [6.4.3 支持 PR197](https://github.com/dscharrer/innoextract/pull/197)（head `93ea8b13553797aab0103108ba0bf59b988d2dbc`）后，静态解包成功，官方 `app/1.5.26.11/` 中确有以下三枚文件：

| 官方文件 | 字节数 | SHA-256 |
| --- | ---: | --- |
| `downloadIPC.exe` | 34,523,272 | `aa091401023fc648fea3832586942e945447d84246ca5be7e3253d349a07ea03` |
| `OrbitSDK.dll` | 8,128,504 | `efefce9a5e418956b2663b1788c28e778eff9e4be80d223c5a97881c9b28af36` |
| `aria2c.exe` | 5,607,416 | `7b04ab13b290ec584d1f8eedc1c830d9f828d0668a2014065af90f38c241d2f5` |

这提供了下载核心确实存在于网易官方产品中的直接证据；它不是对其内部源码的审计。当前官方文件与本项目既有锁定文件的 hash 和大小不同，不能宣称同字节，不能仅因来源更直接就把新版当成既有协议兼容输入。当前 bootstrap 仍按上面的固定 commit 获取；官方分文件直链尚未证实。改为安装器提取还需要锁定安装器字节、提供可复建且符合产品 macOS 支持范围的 Inno 解包闭包，以及重新验证新版核心的 IPC 和两服下载行为。用于本次静态取证的工具有构建机 Boost 动态依赖，不能直接夹进公开 App。

取得或能解包网易安装器也不意味着获得重新分发其核心的许可；本项目不将这些网易二进制纳入 App、DMG 或“对应源码”归档。

## 已证实的协议

上游 [`src/gamemgr.py`](https://github.com/KKeygen/idv-login/blob/6e5523e7933c0c28662b1af2a77e129b512423b6/src/gamemgr.py) 按分发来源区分国服和海外 LoadingBay 元数据接口。海外游戏清单仍提供分发 ID、`app_content_id`、版本号、文件路径、大小、XXH64 和操作类型；上游同时把 `oversea` 布尔值写入下载任务。[`src/main.py`](https://github.com/KKeygen/idv-login/blob/6e5523e7933c0c28662b1af2a77e129b512423b6/src/main.py) 的 `handle_download_task` 在内容 ID、分发 ID 和下载目录有效时调用 `downloadIPC.exe`，将 `--gameid`、`--contentid`、`--targetVersion`、`--repairListPath` 与 `--oversea:1` 一起传入。相同的 ZeroMQ 控制/进度协议定义在 [`src/download_binary.py`](https://github.com/KKeygen/idv-login/blob/6e5523e7933c0c28662b1af2a77e129b512423b6/src/download_binary.py)，不会因海外路由切换。

`ext/v6.3.1-beta-CHANGELOG` 记载该版本支持国际服下载、更新和修复。README 仍另列官方国际服安装器下载链接；它不代表完整性修复必须使用安装器。

这些源码共同证明该上游版本确实将国际服下载接入同一个 `downloadIPC.exe` 命令接口，并显式选择海外服务。它们没有证明网易核心二进制的内部实现，也没有证明所有未来版本、所有分发类型或每一份清单均兼容。

## 本仓实现

### RC4 默认目录首次创建修复（issue #2）

RC3 的安装入口用 `URL` 相等判断是否应自动创建默认目录。目标尚不存在时，从 CLI 路径构造的 URL 不带目录尾斜杠，而显式 `isDirectory: true` 的默认 URL 带尾斜杠；即使 `.path` 相同，URL 仍不相等。创建被跳过后，`directInstallWorkspace` 报“所选安装位置不可用”。两服共用此入口，已有目录会掩盖该缺陷。该失败发生在目录校验，不能归因于可选登录组件或磁盘容量。

RC4 改为比较标准化后的文件系统路径，保留“仅默认目录自动创建”的边界。创建仍在既有迁移之后、同一操作锁内进行，不移回 UI，以免制造 RC1 迁移目标冲突。目录准备抽成实际安装入口与自检共用的函数，避免测试另写一套判断。

回归使用独立临时 home，覆盖两服缺失目录的创建及工作区校验、重复准备保留已有文件、非默认目录不自动创建。旧判断在首个国服缺失目录用例上明确失败；2026-10-15 修复后 `productManager/selfTest.command` 完整通过，包括 RC1 迁移合成测试，`git diff --check` 通过。此验证不代表用户机器上的完整国际服下载已验收，也不能解释其他兼容工具中的 LoadingBay 按钮无响应。RC3 临时办法是先创建空的默认目录再重试，无需管理员权限或安装登录组件；见 [issue #2 回复](https://github.com/FengYinYH/IdentityV-Launcher/issues/2#issuecomment-6176307723)。

国际服 adapter 继续负责从 `api.loadingbay.com` 获取并校验国际服清单，包括固定产品身份、版本、文件路径、大小、MD5、XXH64、CDN 地址和操作类型。首装和修复都把经过 adapter 校验的身份及 planner 所需字段转换为共同 manifest：国际服 app ID 40 作为分发 ID，`h55naxx2gb` 作为游戏 ID，`app_content_id` 作为内容 ID，文件 XXH64 用于计划和下载后的完整性验证。

共同 planner 继续拒绝不安全路径、重复文件、不支持的操作、身份不匹配或无效校验值。共同 supervisor 在任务中显式设置 `oversea=true`，最终给 `downloadIPC.exe` 传 `--oversea:1`。国际服专用 prefix、游戏路径映射、运行中进程检查、Wine 生命周期和发布恢复标记仍由产品管理器控制，下载核心只获得该 prefix 与游戏目录需要的路径。此前 `globalAdapter/download.go` 的独立直连游戏文件下载及其 supervisor 已移除，避免继续维护第二套内容传输协议；`IdentityVGlobalAdapter` 保留为国际服清单与安装器地址解析器。

两服游戏内容首装与修复的传输、清单扫描和下载后复验已共用。各自的安装事务、恢复证据、prefix 和最终游戏链接仍分开，因为它们绑定的是不同产品路径。这个抽取复用了现有 task `oversea` 字段、Wine prefix 准备逻辑、manifest planner 和 supervisor，不改变发布状态机。

### 国际服首装 TLS 库缺失与辅助状态静默修复（issue #4）

国际服首装长时间停在 0 KB 时，下载核心 stderr 出现 `inherited fallback=(null)`、`gnutls_process_attach failed to load libgnutls` 与 `notify client error, code: 304`，而监督器既不失败也不推进。根因是两层叠加：`IdentityVProductManager` 通过 `process.environment` 把 `DYLD_FALLBACK_LIBRARY_PATH=<runtime>/lib64` 交给监督器，但监督器以 Hardened Runtime 构建且未携带 `com.apple.security.cs.allow-dyld-environment-variables`，macOS 在 exec 时清空 `DYLD_*`，该变量在监督器进程内已不存在；`controlledWineEnv` 又只做白名单转发，于是 Wine 继承的是空 fallback，加载不到随 runtime 分发的 `libgnutls.30.dylib`。同一路径上，`304` 这类辅助状态只被转发给 UI 并继续等待，未参与失败判定，也不会被 idle 超时说明，因此失败被降级成无期限的 0 KB。

修复分两处，都在监督器内：

- 环境重建：`controlledWineEnv` 在变量缺失时从任务里已验证的 Wine 可执行文件反推 runtime，按 `<runtime>/lib/wine/<arch>-unix/wine` 与 `<runtime>/lib64/libgnutls*.dylib` 重建 fallback。每一步 `EvalSymlinks` 后再用 `pathInside` 校验仍落在该 runtime 内，并要求 GnuTLS 是常规文件；不满足时返回固定文案（`runtime library directory escapes the selected runtime`、`runtime does not provide the bundled GnuTLS library` 等），不做静默降级。任务 JSON 是用户可写文件，因此其中的路径只作为线索，最终布局由监督器重新解析和校验后决定。
- 辅助状态：`304` 等辅助帧不再刷新 idle deadline，只记录最新的状态码与 payload sha256；终止性帧（显式 `success/ok:false`、非空 `error`、message 类字段含 error/fail、非 JSON 文本含 error/fail）立即以 `core reported terminal auxiliary state …` 失败。错误只带状态码、payload 字节数和 sha256，不带原始 payload 或本地路径，沿袭监督器 stderr 的归一化约定；产品管理器在核心非零退出时把 stderr 交给 UI，因此失败可见。语义有歧义的帧仍交给 idle 超时兜底并附上最后的辅助状态，避免把正常告警误判为失败。

没有采用给监督器加 `allow-dyld` 的路线：它需要重签名、扩大环境变量注入面，且仍要信任调用方传入的外部路径，只是把信任前移。重建加校验保持 Hardened Runtime 姿态，并能对不合法布局给出可诊断的错误。代价是重建逻辑只覆盖上述已证实的 runtime 布局；布局变化时会明确失败，需要随 runtime 升级另行验证，而不是靠猜测继续。

验证使用不依赖真实 runtime 的临时目录布局：缺失变量时仍得到正确的 `lib64`、路径逃出 runtime/缺少 GnuTLS/外来 Wine 布局均被拒、终止性辅助帧触发失败且不刷新 idle、只有辅助帧时不延长进度期限。2026-11-04 `go test -count=1 ./...`（`gameDownloader/` 包 7.999s）与 `go vet ./...` 通过，`productManager/selfTest.command` 通过。这些是 Go 侧合约测试：本机没有据此重签名、公证或重装 App，也没有跑真实 17.6 GB 国际服首装，因此用户机器上的端到端验收仍待带新签名的候选完成。

### PR #5 与本机 RC5 的整合审查（2026-11-05）

审查 [PR #5](https://github.com/FengYinYH/IdentityV-Launcher/pull/5) 精确提交 `c15101a964d6096c9dfff7da186414217ac5bab7`，base 为 `0896cd9`。当时远端 PR 仍开放、标记可合并，没有 review 或 CI 检查记录；这是相对远端 RC4 基础的状态，不代表能无冲突合入本机 RC5。并行本机分支已经推进至 `e151416`，包含 `f8b4e01` 的路径/辅助状态改动、RC5 候选及后续启动修复；原日用源码与运行状态未因本次审查改变。

PR 与本地早先隔离修复 `7531ae5` 解决同一个签名边界问题。PR 严格匹配完整 `lib/wine/x86_64-unix/wine` 后缀，并拒绝将含 `:` 的派生目录作为单一 DYLD 路径；有效显式继承值仍优先。两者的次要差异是无效的换行继承值：PR 丢弃而不重建，早期隔离修复丢弃后重建。PR 不增加 entitlement、不修改证书或 TLS 校验；在该窄范围内未发现阻断问题。不要重复提交两套同义修复。

独立验证严格区分提交与验证层：

- PR **原样提交**的 `gameDownloader` 执行 `go test -count=1 -timeout 60s ./...` 通过（5.997s），并成功构建 supervisor。PR 自带四例覆盖缺失值、显式值、其他布局和缺少 lib64；名为“signed supervisor”的用例只是设置空环境，不是实际签名测试。
- 审查临时增加的六个边界用例均通过：变量确实 unset、lib64 是普通文件、同目录非 Wine 可执行文件、runtime 路径含冒号、显式多路径和含换行的显式值。临时测试不加入 PR，审查后移除。
- **实际签名边界**：将该 PR 编译的 supervisor 本地 ad-hoc + Hardened Runtime 签名，不赋 allow-dyld entitlement；用与此前对照相同的 x86_64 原生探针加载实际 bundled GnuTLS，观察到 fallback 存在、加载成功、`gnutls_global_init` 返回 0。探针故意退出 1，supervisor 的非零退出是该诊断的设计，不是下载回归失败。
- **未对这个 PR 精确提交执行**：完整 App 构建、真实文件下载、全量首装或游戏启动。报告者区分了此前本地补丁的 8.8 MB 观察与 PR 分支的自动化测试，不能把前者写成该提交已完成全量安装。本机 RC5 文档记载的后续安装/启动结果属于另一条源码链，亦不能转记为 PR 验收。

整合建议：保留报告者贡献与本机已完成验证，逐项协调后再决定单一实现，不直接 cherry-pick/覆盖。`git merge-tree --write-tree` 的只读整合预演确认 PR 与 `e151416` 在 `STATUS.md` 和 `gameDownloader/supervisor.go` 冲突；测试文件能自动合并，不表示其语义已经适配。当前 RC5 的 `controlledWineEnv` 已返回 `([]string, error)`，并有 `EvalSymlinks`、路径留界、GnuTLS 常规文件及 fail-closed 校验；PR 保持旧 `[]string` 接口和未知布局兼容行为。不能将任一差异悄悄覆盖，整合后需要重跑模块测试并以实际决定的生产源码复验签名边界。当前 RC5 派生路径也没有 PR 的冒号防护，建议在后续统一实现时保留该边界测试。

**独立于 PR 的当前风险**：RC5 的 `auxiliaryFrameFatal` 根据任意 message 文本的 `error`/`fail` 子串判断终止，合成反例 `{"message":"no errors"}` 与 `{"message":"retry after temporary failure"}` 均返回 true。它们仅用于证明启发式的误判可能，**不是厂商真实 payload**。现有记录没有证明这些文本模式等同终止语义，不能因本机正常安装成功而认定所有辅助状态分类正确；需要真实 304 第三帧、前后状态/字节、重试和最终结果，形成脱敏 fixture 后再决定分类。本轮不为缺少证据的语义写补丁，也不推送、批准、合并或回复 PR。

### RC5 国际服安装完成后启动预检失败（2026-11-05）

在源码 `b27457c` 对应的 RC5 build 9 日用候选中，国际服安装完成并发布游戏/prefix 记录后，启动仍失败；已安装运行器的 `--preflight --product global` 返回 `prefix has an invalid volume UUID`，尚未进入 Wine。原因是产品管理器的 `ProductState.installations` 类型为 `[ProductID: Installation]`，其中 `ProductID` 是枚举。Swift Codable 对这种字典编码为交替键值数组，例如 `{"installations":["mainland",{…},"global",{…}]}`；运行器却把它当作对象，固定读取 `installations.global.prefix.volumeUUID` 等路径，结果全部为空。数组顺序由字典决定，不能固定为某个索引。安装成功与此启动失败并不矛盾：管理器自己用 Codable 解码能够读回记录，跨语言的 shell 消费者才发生不匹配。

修复在两份 runner 模板共用的同内容脚本中解析产品记录：数组必须是至多两组有效产品键与字典值，拒绝奇数长度、未知键和重复键，查找目标产品后再读取其 prefix/gameRoot；同时保留原有对象表示的读取能力。后续磁盘 UUID、相对路径、runtime 摘要与 prefix/gameRoot 绑定检查照常执行。保持现有持久化格式，不迁移或重写用户配置，不重新下载游戏。

`gameRunnerApp/tests/gameRootBinding.test.command` 增加真实 Swift 枚举键字典编码 fixture，并覆盖国际服在数组首位/末位、仅国际服、对象表示、缺失/重复/无效记录；该脚本已在玩家完整构建的自检列表内。针对性检查通过，修复后的源码运行器对现有国际服及国服分别预检成功。随后从修复提交 `fd3f3e8` 完整构建成功，成品两服预检及深层签名检查通过；安装器更新同一日用位置并正常重开后，从国际服按钮启动的真实游戏窗口已显示文件检查，继而进入官方首启热更新（约 3.5 GB）。后续约 3.5 GB 更新完成并显示官方重启确认，正常确认退出后，从同一日用启动器再次启动国际服成功；新会话显示国际服官方公告、标题/登录场景及着色器编译，资源版本已更新至 `2.0.3087898`。这完成了本机“安装→启动→首启更新→重开→可见标题/登录场景”的验证；没有代用户完成账号登录，不宣称大厅、对局或中断续传已经验收。

## 结论状态与边界

- **已证实**：指定上游提交把国际服元数据、内容 ID、分发 ID 和海外标志交给同一下载核心命令接口；本仓任务结构及 supervisor 已支持 `oversea` 参数。
- **已证实**：本次实现把两服首装及修复纳入共享 planner、下载核心和下载后复验，并保留国际服产品身份、隔离 prefix 与独立发布状态机。
- **已证实**：2026-10-05，锁定 core 在独立 RC2 Wine prefix 中真实写入国际服官方清单的 `engine_version`，58 bytes，监督器约5.621秒成功结束并报告state8。MD5 `7a761a68666930bd586153564794b365` 和XXH64 `a3ef684994e09fd0` 均通过planner复验（1/1、repairs0）；不是以CDN直连替代核心执行。任务未调用登录安装器或登录启动流程。这只覆盖一个真实文件，不等同17.6GB全新安装或所有更新操作已验收。

RC2最终核验另发现产品管理器验证国际服的 `C:\\Games\\IdentityVGlobal` 映射后，却向修复任务返回固定国服根。已改成沿已验证产品返回对应Windows根；两服实际修复路径解析函数的fixture先在旧实现上失败，再在修复后通过。共享下载核心不会因此借用另一服目录。
- **已证实（2026-11-04）**：Hardened Runtime 下监督器收不到 `DYLD_*`，由监督器反推并校验 `<runtime>/lib64` 可恢复随 runtime 分发的 GnuTLS；终止性辅助状态（如 `304`）现在会让监督器以带状态码和 payload 摘要的错误结束，而不是停在 0 KB。Go 合约测试通过；真实签名候选的端到端首装尚未执行。
- **已推翻**：本仓此前注释把国际服下载核心协议表述为不能与国服共用。该结论与上述上游源码不符；源码证据支持首装和修复都使用下载核心，因此本次移除了重复的 global 直连文件下载器，同时保留仍承担产品解析职责的 adapter。
- **仍未知**：当前网易二进制对国际服所有更新操作、实时服务可用性、特定网络环境与 Wine 版本的实际兼容性。源码级协议证据和 Go/Swift 合约测试不替代真实国际服下载、更新或修复回归。

切换带来的主要失败路径变化是：国际服文件下载不再由本仓 `globalAdapter` 逐文件暂存后原子替换，而改由网易 core 按 repair list 执行，与国服采用相同的写入和续传机制。修复前 planner 根据 XXH64 扫描并生成 repair list；核心非零退出或被取消时，产品管理器不更新已安装版本记录，并收束该 prefix 的 Wine server。重试会重新扫描当前游戏树并生成新 repair list，因此缺失或摘要不符的文件仍能被发现并再次交给核心；核心返回成功后还必须通过整树 planner 复验才更新记录。首次安装的失败会留下 `downloading` 事务标记和隔离 staging 目录，正式目录链接及安装记录不会发布；同版本重试重新生成完整 repair list 并复用 staging，若清单版本变化则拒绝混合续传。没有证据表明核心在单个文件中断时原子写入或保留旧文件，因此修复期间目标文件可能暂时不完整，但下次 planner 会检测并重试；launcher 的 prefix/运行进程检查和操作锁避免对活动客户端执行修复。

本轮 `go test ./...` 已分别通过 `manifestPlanner/`、`gameDownloader/` 与 `globalAdapter/`；`productManager/selfTest.command` 通过，覆盖身份转换、海外任务参数和产品特定热更新判断。真实游戏文件和运行进程不属于这些合约测试的证明范围；国际服核心的单文件写入/中断行为及真实网络下首装续传仍需实机验证。
