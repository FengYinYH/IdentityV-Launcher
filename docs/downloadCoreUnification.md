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

### 两种下载修法的取舍与 #6 复核（2026-11-05）

追加审查固定本机 `e151416`、PR #5 `c15101a`，不是把本机端到端观察转算为外部 PR 的验证结果。

| 维度 | PR #5 | 本机 RC5（`f8b4e01` 后） | 评价 |
| --- | --- | --- | --- |
| 根因处理 | 在 exec 前重建 fallback，完整匹配 x86_64 Wine 后缀，要求 lib64 目录存在 | 同样重建，解析 symlink、留界、要求有常规 GnuTLS 文件，失败有归一化错误 | 两者对当前有效 runtime 都能处理路径丢失；更多检查不等于动态库/信任已获保证 |
| 输入与兼容 | 拒绝含冒号的派生目录，未知布局保留旧行为 | 未拒绝冒号，接受任意 `*-unix` 和同目录非 Wine 文件名；未知布局 fail closed | 本机合成目录已复现冒号及 `not-wine` 被接受；PR 边界更精确，本机扩展了失败条件与布局契约 |
| 校验价值 | 小而易审查，不校验 GnuTLS 闭包 | 缺库/外逃提早报错，适合当前固定 catalog，但存在显式继承值绕过这层检查的行为 | 这不是新增完整信任边界；manager/catalog 原有 hash 验证仍是内容契约，不能以存在某个 dylib 冒充库可加载 |
| 故障处理范围 | 不改辅助状态 | 同时改变辅助帧 idle 与 `error/fail` 文本终止分类 | 不延长辅助帧 idle 有明确价值；任意文本子串推断终止缺乏协议依据，应单独处理 |
| 可维护性与验证 | 生产改动约 15 行、四例测试；本次原样模块、六项边界及真实签名探针通过 | helper/接口与调用测试改动更大；本机已记录完整构建及安装/更新/登录场景，追加模块测试通过 | PR 更适合作为窄修复的起点；本机验收更广，但不能证明所有新增防御或 304 分类正确 |

**具体推荐**：最终只维护一份实现。对于路径恢复，优先采用 PR 的明确后缀、冒号防护与显式值优先策略，保留本机已有调用方错误传播及对当前 catalog 确有必要的缺库诊断；若继续要求留界，则把它作为明示的固定 runtime 契约，测试内部/外部 symlink、有效别名与未来布局，不宣称是完整安全验证。不要为合并而反复改接口，也不要丢弃已经完成的 RC5 启动修复与验证。所有者若选择 PR 的最小兼容路线，也合理，但须明确不再对未知布局提前拒绝，而不是悄悄降低原有承诺。合并前补精确文件名/冒号/空变量去重边界，并用最终统一源码跑模块、签名边界和真实受限下载。当前本机转发空 fallback 后又追加重建值，可产生同名空/非空双条目，也应在统一时去重。

对 304 应保留受限摘要与辅助通知不刷新 idle 的改进，撤去或收窄未经真实载荷证明的文本终止猜测；普通进度帧还会刷新 idle，故不能把这项变更称为所有 0 KB 卡住的解决方案。这是审查建议，本轮没有改产品代码或安装日用 App。

**#6 实际是 [PR #6](https://github.com/FengYinYH/IdentityV-Launcher/pull/6)**，精确 head `dee483eb8ed99016fbce4815c80d072238c88a8a`，与本机 `fd3f3e8` 同样修复 Swift 枚举键字典被编码成交替数组的问题；不是磁盘 UUID 损坏，不需要搬游戏或重新安装。本次原样 `globalProductsLayout.test.command` 通过，本机 `gameRootBinding.test.command` 也通过。PR 从偶数位查找 global、最多扫描 64 个位置；本机一次定位并校验至多两产品、偶数长度、键和值类型及重复键。合成重复 global 记录中，PR 选首项，本机拒绝；这不证明正常记录有问题，但本地版本的畸形输入约束更完整，且使用真实 JSONEncoder fixture。因此建议保留本地解析修复，吸收 PR 对 `\/` 转义及值位置 `global` 的明确测试，而不重复覆盖两份 runner。

**#6 附带的 IDV-LAUNCH-299 仍需修**：`launch`/`restart` 在 preflight 和游戏进程出现之后，再用只读旧国服 `installation.json` 的 `legacyBinding()` 取得 runtime（`IdentityVProductManager.swift` 当前约 2311 行）。只有国际服、没有国服旧记录时 guard 必败，进入通用 299 分类；游戏可能已在运行，重试会造成误导。这独立于 runner 数组读取，不能因本机同时装有国服时启动成功就判定已修。建议按当前产品的已验证 runtime-binding/catalog 取得 activator 的 expected executable，保留进程身份检查，不能跳过窗口验收或把任意存活进程当成功。先覆盖仅国际服无 legacy、双服不同绑定、失效 runtime、启动后退出等合成场景，再验日用入口不误报、不重复启动。本轮未启动新游戏来复现，也未改账号/产品记录。

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

## RC5 build 10 整合候选（2026-11-05）

在上述审查后，所有者授权整合与隔离全量验收。路径恢复采用 PR #5 的完整 x86_64 Wine 后缀、单路径防护与显式值优先，保留已知 profile 缺目录/GnuTLS 的早期错误；移除把 lib64 别名视作新信任边界的重复策略，catalog/hash 仍由 manager 负责。空变量只输出一个条目。未知布局不猜测，保持 PR 的兼容行为。已移除不透明辅助消息的 error/fail 子串终止分类；已知终止状态和非零退出仍失败。辅助通知不续期，进度速率/私有字段变化也不续期，阶段、总量、百分比变化才重置 idle；启动/idle 超时都附受限状态/摘要。此候选不声称知道 304 的未公开 payload。

启动确认改用已验证的 runtime-binding，避免只有国际服时读取不存在的国服 legacy 记录而误报 299。新增自定义安装位置和只读已有目录检测，外部文件保持用户所有权。当前针对性测试已通过，整体构建、打包和新 HOME 下的完整下载/安装/启动正在验收，不能把候选代码等同已经交付。

鼠标捕获：复查 2026-10-28 运行日志及现存 Dense 诊断，未找到 CGCursorIsVisible/ClipCursor 约束切换记录。仅有一次指针可自由移动的现场描述，仓内存在的 ClipCursor-reset patch 不能证明与事件因果有关。本轮不改鼠标运行时；重现时需记录前台/窗口、系统全屏/焦点变化、具体 runtime、按键/鼠标相对移动与约束状态，避免录入账号、聊天或原始输入内容。

### 国际服基础清单修复的回退保护

本轮只读核对现用国际服公开 engine_version 标记，其格式与国服同为 `release_YYYY_NNNN:<40-hex>`，但实际字节与当前官方基础 manifest 的 engine_version 不同。原实现明确跳过国际服保护（已有测试甚至要求继续下载）；因此对已在游戏内更新的国际服调用基础清单修复可能回退正常引擎文件。候选现将同一保守保护扩展到两服：仅当 repair list 包含 engine_version 且当前标记满足小型常规文件/格式校验时阻止基础包下载，并提示使用游戏自身更新/修复。没有将任意 mismatch 都当热更新或忽略，真正与当前基线一致的 marker 不在 repair list，其他损坏仍由现有流程处理。此处不修改当前用户游戏；全新测试和回归另记。

## RC5 build 10 验收检查点（2026-11-05，源码 a9bc18f）

- 完整候选构建成功，签名树与 31 个 Mach-O 的 macOS 14.0 部署目标检查通过；日用 App 仍为旧 build 9，未替换。
- 在无游戏/国服记录的新 HOME 首次安装国际服，默认目录起初不存在、由管理器创建。固定 runtime 从原始来源下载并验证；网易 core 按锁定 hash 获取。全新数据曾推进约 14.87 GB，真实暂停/恢复和取消得到核心响应；改用最终候选清除旧控制状态后续传，完成 17,602,266,736 bytes、下载后整树校验及安装记录发布。既有用户游戏和账号不参与此树。
- 进度 JSONL 最后记录 verifying/completed，监督器正常成功结束；其成功条件仍是既定 finish/state-8 与零退出握手，本轮没有额外保存原始全部 IPC 帧。实际日志未观察到 304，不能将正常安装成功当作 304 分类证明。
- 最终签名管理器的只读 inspect：官方国际服基础包 444 文件、零 repairs；仅损坏本轮隔离树的 58-byte engine_version 时准确检测到一个 mismatch，随后恢复原字节。两服不完整合成目录分别返回未验证（444/439 repairs）；缺失目录、文件路径及未知产品被拒，原测试文件 SHA/列表保持不变。
- 无国服 legacy 记录的隔离国际服 prepare-launch 已通过实际 runner 预检。尚未真正启动新游戏、热更新或进入账号/大厅/对局；旧国际服一直保留运行，需确认适合退出后再验新窗口与日用入口，不能把预检称为进入游戏。
- 封包器完成纯本地 ad-hoc 测试 DMG（约 28 MB）、对应源码/许可 ZIP（约 177 MB）、载荷检查与只读挂载复验，复制后 SHA 清单通过。这是内部包，未公证、不可当公开发行或替代日用 Developer ID 候选。Apple App/DMG 公证提交在执行前被自动审批拒绝，理由是当前授权未明确允许向 Apple 发送私有构建产物；没有提交，也没有绕过该拒绝。等待所有者明确授权后才能继续正式公证。
- 本机构造的超长测试 HOME 曾导致 Wine kernel32 加载失败；移动后又发现 Wine 以 loader inode 缓存的 ntdll 链接指向旧路径。只清理确认属于本轮测试 inode 的缓存；使用较短 canonical HOME 后成功。另一次 /tmp 别名被核心获取器的 symlink-ancestor 检查拒绝，使用其物理 /private/tmp 路径通过；没有降低产品校验。初轮独立工具副本还曾在整包完成前复制而缺组件清单，已以完整候选纠正；这些失败均不能算作游戏安装通过。
- IDV Login 合约 9 的恢复判据、状态工具及 fixture 通过，但尚未更新正在使用的 root helper，也未删除现有 CA/账号制造首次现场。首次系统信任交互仍需明确授权与合适的隔离环境；鼠标捕获事件无新复现，保持调查状态。

阶段状态是“独立下载与检查完成，等待原游戏可退出及外部公证授权”，不是卡在下载，也不是已经完成真实进入游戏。源代码置于原 Mac 项目的独立工作树，保留原分支与运行状态；没有推送、合并 GitHub PR 或对外回复。


### RC5 build 10 日用与隔离验收补记（2026-11-05）

完整签名 App 已通过正常本地安装入口更新日用位置；安装前后原有产品记录与 runtime 绑定哈希未变。本地测试包未公证，不作为公开发行产物。隔离国际服完成官方基础清单 444 文件全量安装和最终复验，暂停、取消后续传通过；单文件损坏检测后恢复原字节。完整已有目录导入仅在隔离状态目录提交，GUI 检测弹窗选择取消，未替换用户绑定。新日用包通过产品管理器启动隔离国际服并确认窗口，未凭进程存在宣称登录或大厅通过；画面验收受屏幕录制权限阻挡。首次 CA 恢复仍缺全新系统交互证据，现机 helper 契约为 8。

实机发现服务器面板切换重建 presentation 时遗漏新增路径与基础清单校验字段。后续 build 11 改为复制原值后只改变选中状态，避免新增字段再次被丢弃；模型回归覆盖路径、明确 false 校验值及往返切换，已通过。build 11 干净源码 8ac9778 完整 Developer ID 签名构建与全部自检通过，31 Mach-O 部署目标审计通过。后续新需求并行处理中，未替换活动中的日用 App；最终整合包仍需统一更新与回归。


### 隔离国际服更新后重启与画面核验（2026-11-05）

所有者明确允许发起屏幕录制权限请求及关闭游戏进程后，预检确认屏幕录制已授权。精确目标窗口截图显示隔离国际服停在官方“更新完成，需要重启”提示，并非凭进程存活推断运行正常。随后通过同一日用 build 10 的产品管理器，在隔离状态目录执行正常 stop/launch：停止输出确认只收束国际服已验证会话及独立 Wine prefix，国服和 IDV Login 不受影响；启动返回成功，无 299。重启后目标窗口显示当日国际服更新公告，后台进行着色器编译。

这通过了基础全量首装、游戏内更新、正常重启及公告场景，不等于账号登录和大厅通过。CUA 对游戏名称绑定失败，Wine 窗口不在可控制 App 清单；截图只作只读核验，没有改用其他方式注入鼠标/键盘事件。已请求所有者关闭公告及必要时完成账号登录，再继续画面核验。私人截图留在临时目录，不进入仓库。反馈补丁原有审批阻碍未解除，也未重试。


### 所有者确认本轮国际服验收终点（2026-11-05）

所有者说明没有国际服账号，且有网络限制，明确“能到公告页面就算完成目标”。按此验收标准，前述隔离国际服从空目录全量安装、游戏内更新、正常停止/重启、实际公告画面已完成本轮启动验收。关闭等待用户登录的待办，不再尝试登录或进入大厅；账号登录、大厅和对局未测试。此结论不代替后续新改动整合后最终包的针对性回归。

## 304 全材料及通信复核（2026-11-05 后续）

重新读取 #3、#4 全文及全部评论、PR #5/#6 补丁，无需报告者提供新包。#3 的未知 304 立即退出是协议兼容问题；#4 的 TLS 错误、GnuTLS 加载失败及 fallback=null 提供了独立的明确根因，不能再描述为“完全缺乏真实 304 证据”。库路径恢复已纳入 RC5，隔离国际服全量安装通过。缺少的是 304 第三帧的精确厂商 schema，因此不能将状态码等同 HTTP 304，或猜测所有 304 都终止/可忽略。

当前监督器验证三帧、内容 ID 和 payload 上限，304 只输出受限摘要；辅助帧不建立进度通道、不延长 startup/idle，重复速率与私有字段变化不延长 idle；已知失败码/非零退出失败，只有 state 8 完成握手并零退出才成功，随后管理器独立按 manifest 校验文件。故原报告的未知码退出和库缺失已处理，持续只有 304 时会有限超时并携带状态摘要，尚不能即时解释每一种 304 的厂商内部原因。原始 payload 不写公开日志。现有合成 ZeroMQ 测试覆盖失败词不被猜测为终止、辅助帧不续期和进度停滞；不伪称真实厂商第三帧 fixture。当前无需进一步猜测性协议补丁。

截至本次 GitHub API 两次查询，公开 open PR 仍只有 #5 与 #6。#6 HEAD `dee483eb8ed99016fbce4815c80d072238c88a8a` 的实际文件仅修 runner 的数组/对象读取并增加测试，正文明确将 299 列为未修；没有发现独立 299 新 PR。RC5 基线已有按当前产品 runtime-binding 确认窗口的修复，不能把“未找到新 PR”解释成“299 未改”。若新 PR 随后出现，应按链接另作 diff 审查，当前不重复合入 #6 的较宽松 parser。


## 路径与登录新候选的 RC5 build 12 整合（2026-11-05）

从独立候选 96504d8 安全应用到已有 RC5 修复上，手动解决 STATUS 与本专题的历史快照冲突，保留公告页验收标准和已完成实测。最终源码 9d4440b；补充 helper 契约 9 不兼容回归，更新地图中的文件级导入入口，并保留升级/回退与用户缓存说明。自定义路径允许无关兄弟文件，拒绝覆盖已有事务子目录；卸载仍只移走已验证游戏根和独立 prefix，不移走选择的父目录及其无关文件。外部导入仍保留原文件所有权。

完整从头构建通过，包含产品管理器 sentinel 与事务目录保护自检、路径发现 fixture、模型/进程自检及 237 三语言键核对，签名身份和 31 Mach-O 部署目标审计通过。本地 VM 测试 DMG 另行封装，不执行 Developer ID 公证流程；保留候选 App 签名，实际项目载荷审计、只读挂载签名及 build-provenance 一致性复验通过。材料 ZIP 的源码提交与 App 相同，统一 SHA-256 清单复算通过。构建仍有原有计时器 actor 警告，不将其描述为零警告。

这不包含此前被审批拒绝的反馈社区补丁，也没有替换系统 helper、导入证书、变更 hosts 或证明新组件真实账号登录可用。干净 VM 从零下载/安装是后续独立验收，不能由本机打包通过替代。


### build 12 实际 UI 回归与 VM 接续边界

按所有者指定的模型偏好，由 Terra 执行模拟点击测试。实际进程来自确切 build 12 候选目录，简中、繁中、英文均检查游戏位置旁的导入按钮，未见截断。文件选择器可选 dwrg.exe，调用实际 inspect 并出现确认；隔离国际服完成热更新后按基础清单为 444 文件、6 处不匹配，显示可能热更新/服务器未验证的提示，取消后保留用户原路径。以国服检查该国际服目录出现更多差异，同样没有自动导入或修改文件。

错误可执行文件 dwrg_repair.exe 没有进入检测确认，路径保持原值；未捕获四秒操作提示，不能宣称错误提示已验收，也没有凭这一点猜测新增修复。因两服已有安装，实际默认/自定义安装取消流程仍待干净 VM。测试后恢复原语言选择和国服，正常退出候选，独立 PID 复核确认进程不存在。新 helper、CA、hosts 与登录组件的系统运行状态未被此 UI 回归改变。


## build 13：304 锁定定义与按实际产品 runtime 确认（2026-11-05）

本节取代此前“304 仅不透明辅助状态、等待超时”的暂定结论。核心来源为本仓清单锁定的 downloadIPC.exe，34,378,168 bytes，SHA-256 `5c11d3188d271c1df88d36d98bb440437d29e8a41c88dfd38602ce3c60c56f82`，上游固定资源为 https://github.com/KKeygen/idv-login/blob/9b1ff598da6cb9ae6a952a8978ccf88bc8b2ae5c/binaries/downloadIPC.exe 。独立静态审查定位如下，本轮再次复核实际文件 SHA 和 `0x14042ec46` 的 304 立即数及随后的 Panic 调用：

| 位置（PE 虚拟地址） | 可复核事实 |
| --- | --- |
| `common.DownloadManifestByUrl` `0x14042e9a0` | 清单取得函数，不是 HTTP 状态处理器 |
| `0x14042eb1b` / `0x14042ef5b` | 计数初始化 0；每次 Downloader.Download 返回后递增 |
| `0x14042eb49` / `0x14042eb4d` | 比较计数 10，≤10 继续尝试；超过时进入失败分支 |
| `0x14042eb63` | 拼接 `, try count exceeded ` 和清单上下文；不是正常缓存通知 |
| `0x14042ec46` / `0x14042ec4c` | 将 `r8d` 设为 `0x130`（304），调用 `base.(*errorCollector).Panic` |
| `base.ErrorHandle` `0x140353f61`–`0x140353f71` | 从恢复的错误对象取消息与代码，交给 NotifyClientError |
| `NotifyClientError` `0x140353380` | 将字符串及代码入错误 channel，日志模板为 code/msg |
| `main.ExceptionCallback.func1` `0x14049b6b1`–`0x14049b6bc` | 读取同一字符串与代码，传给注册的回调 |
| `main.main` `0x14049cfd7`–`0x14049cfe0` | 异常回调注册到与进度相同的 sendMsg；函数值 `0x140734a40` 指向 `0x14049bc60` |
| `main.sendMsg` `0x14049bc92`–`0x14049bd02` | content ID、十进制代码、原始字符串分别转为字节；第三帧没有强制 JSON 包装 |


这些控制流证明当前锁定核心的清单重试计数超过 10 后发出任务错误 304；内部 Downloader 可能还有自己的请求尝试，不能等同恰好 11 个 HTTP 请求。异常和进度共用 sendMsg，第三帧为原始字符串，不保证 JSON。TLS/GnuTLS 可以是底层原因之一，304 也不是 HTTP Not Modified。可通过 `go tool nm` 与 `xcrun llvm-objdump -d --x86-asm-syntax=intel --start-address=0x14042e9a0 --stop-address=0x14042f3e0 "$CORE"` 对该精确文件复核，不运行核心。

监督器现按代码 304 立即失败，不解析/猜测第三帧文本；只输出字节数和 SHA-256，错误明确为清单重试耗尽。原始文本、空帧、JSON 三种合成 ZeroMQ 回归验证立即失败、无完成事件、无路径/token 泄漏；其他辅助帧继续不续期，正常完成与非零退出回归保留。语义仅适用于当前锁定字节；新增跨清单 hash 契约测试，更新核心 pin 必须重新审查，不可将此定义无条件外推。真实厂商 304 尚未在本轮动态重现，这些是静态证据和合成协议回归。

PR #6 的正文指出的仅国际服 legacyBinding 误报路径成立；其补丁主体仍仅处理 Codable 数组/对象解析。新增发现是国服 runner 读取 legacy runtime A，而先前 RC5 统一用共享 runtime B 确认窗口。现在启动前固定当前产品预期 Wine 身份：国服调用 activeLegacyRuntime（匹配安装记录并校验 catalog/hash），国际服调用已验证共享绑定。失败不向另一绑定回退；随后仍验证 PID、精确 loader 和可用窗口，不跳过窗口检查，不自动二次启动。单元回归覆盖仅国服无共享、仅国际服无 legacy、A/B 不同、无国服安装、校验失败不借用另一服；用已退出的本任务子进程调用实际 activator，返回 invalid_target 且非零退出。A/B 不同的真实游戏动态场景尚未制造，不能把 resolver fixture 当实机复现。


### 真实 304 帧接续（2026-11-05）

独立缓存探针在不改变宿主信任的隔离代理环境中，已从锁定真实核心捕获 464 字节明文 304，SHA-256 为 `a6e986445ec4677d9219ed8a5e5e555d37c637a9aa5f80bfb907ba15d9b431da`，内容包含清单下载失败、TLS 信任失败及 try count exceeded；序列为 2→304→重复10。它与静态清单重试失败定义吻合，但不证明原 issue 都是同一 TLS 原因。已将真实第三帧字节在临时测试副本交给同一监督器源码回放，通过立即失败与受限摘要检查；原始载荷留仓外，不编造厂商 JSON。公共回归另外覆盖2→304→重复10的结构，确保已建立进度后也不被辅助状态拖住。


## PR #5/#6 作者历史保留评估（2026-11-05，仅隔离实验）

所有者希望正式 GitHub 记录保留贡献者痕迹。本节仅报告隔离实验，没有把评估分支合入现工作分支、推送或改变 PR 状态。核查时 main 为 `0896cd9c0149c52de94a22697d2170429a71af4a`，两个 PR 均 open、merged=false、mergeable=true；作者显示为 Bloody-Regina，对应 PR 提交者 BloodyReginaa。#5 原始头 `c15101a964d6096c9dfff7da186414217ac5bab7`，#6 原始头 `dee483eb8ed99016fbce4815c80d072238c88a8a`，各一个提交且基于同一 main。仓库允许 merge commit、rebase 和 squash；正式操作前还须复核当时的保护规则、检查和最新 PR 头，不能以本次快照替代。

### 实验、冲突与最终树

从当前 main 开始先用 no-ff 保留 #5，再用 no-ff 保留 #6，两步彼此均干净合并。随后合并已验 RC5 `51760a922d8a4c03faf180df06f099f92395fae1`，冲突为 STATUS、supervisor.go 及两份 launchIdentityVRunner，共四处。保留当前严格实现后，自动合并仍额外带入三个文件的 176 行测试/构建变化：旧 PR5 测试将 controlledWineEnv 当单返回值而编译失败，原 PR6 测试依赖 global_installation_raw 名称而无法定位当前 parser。这证明机械解决文本冲突不足以得到可用候选。

临时实验最后将树明确调和到已验 RC5 快照，记录调和的 merge commit `d7ec823462aa0a7ab30f42f8aa406f34ab1aeeaa`；它的父提交为“已合并两原 PR 的实验链”及原 RC5 提交。merge-base 检查确认 #5、#6 和原 RC5 都是该头的祖先；三个原始 SHA 与 author 信息保持不变。实验树与原 RC5 树均为 `d9cfc75beda275ba694814f1388923c259716503`，git diff 为零。调和后 Go 全模块与实际 gameRootBinding 合成回归通过，两份 runner 字节一致。未把 d7ec823 当成已构建/已签名候选。

### 推荐及 GitHub 状态条件

推荐保留上述“原 PR 提交 + 明确调和提交”的 merge 历史，保留现有更严格实现和诊断，不让旧测试接口迫使代码退化。可以在后续获准的独立整合 PR 中携带这些原始祖先，再以 merge commit 合入目标 main；也可先在 GitHub 分别合并原 PR，再立即调和 RC5，但这会让 main 出现中间态，应结合 CI/自动发布行为选择。本轮没有实施任何远端步骤。

本地出现原作者提交不等于 GitHub 已 merged。GitHub 文档说明，当 PR 的原始头提交经其他路径在实际 base 分支可达时，可以标为间接合并；在各原 PR 页面执行获准的 merge 也会留下其正式合并记录。仅把新整合分支留本地或推到别的分支不满足 base 可达条件。对整合分支做 squash/rebase 会改变 SHA，不能再依赖本实验的原始祖先证明。实际采用时仍按规则和检查执行，不能利用间接合并规避保护。参见 [GitHub merge/indirect merge 说明](https://docs.github.com/en/pull-requests/reference/pull-request-merges)。

替代方案：cherry-pick -x 可保留原 author 并引用原 SHA，但会生成新 SHA，不保证原 PR 自动变 merged；分别在原 PR 执行 squash/rebase merge 可留下各自 merged 状态，但不保留所有原始 SHA；仅写致谢或经确认的 Co-authored-by 也能表明贡献，但不等于原 PR 合并。共同作者邮箱应由贡献者确认，不随意编造。GitHub profile/contributors 统计还取决于默认分支可达及提交邮箱与账号关联，不应承诺每行 blame 或即时统计都显示同一作者。参见 [贡献统计条件](https://docs.github.com/en/account-and-profile/reference/profile-contributions-reference)和[共同作者信息](https://docs.github.com/en/pull-requests/how-tos/commit-changes/creating-a-commit-with-multiple-authors)。

测试成本分层：相同最终树允许沿用已有功能证据，仍应运行 Go/严格 parser/关键绑定负例并复核树；若采用新历史，App 的 sourceCommit、对应源码包和材料身份改变，必须从新 clean HEAD 重建/签名/打包、生成新哈希，再做日用入口烟测和最终包身份验收。不能直接把 build13 的旧签名包或 DMG 哈希挂到新历史上，也无需仅因历史变化再下载全部游戏来冒充新增功能验证。后续若代码或输入变化，则按变化扩大回归。

## build 13 本机交付验证

干净源码 51760a9 完整构建与全部检查通过，新增 symlink-root/empty-root 审计回归也通过。完成本地 VM 测试 DMG、对应源码材料 ZIP、只读挂载签名/身份复验及 SHA-256 复算；没有公证。DMG SHA-256 为 `b1d77feb98047b745c3ad2b35e51619e3750b5dc8da22e014722c9f6e03eda8b`，材料 ZIP 为 `f60eb18948c75990cc08d2872630794b38e3a0e23799411f545a0ce104d09a04`。

通过正常安装入口更新日用 App 到 build13，保留旧版备份；安装后与 Terra UI 烟测后，原 products/installation/runtime-binding 字节哈希均未变。Terra 从确切日用路径确认两服状态/路径正常、旧 helper 对应需要更新状态符合预期，正常退出后独立进程核验已无启动器实例。实际用该日用包 manager 在无国服 legacy 记录的隔离 HOME 预检并启动国际服，返回成功且截图确认当天公告，无299；按所有者验收终点完成后正常结束隔离国际服，国服和登录代理保留。A/B 不同的真实游戏、macOS14、全新 CA 和新633系统组件运行仍未由此覆盖。反馈补丁仍未应用。


## PR #5/#6 真实合入与正式 RC5 调和（2026-11-05）

在所有者明确批准顺序操作后，重新核验远端main0896cd9、PR5头c15101a和PR6头dee483e均未变化、可合并；仓库允许merge commit，目标main没有随push自动发布Release的workflow。通过GitHub的merge方式逐一合入，并用expected_head_sha固定原提交：#5 merge commit `75aad464bfbb12dfe93f21a08c4beeeb35d56548`，#6为`91aadb15adda663efbea6e847afa3421111385a6`。再次查询均closed、merged=true，远端main指向91aadb1，两原始作者SHA均可达。

真实合并后的树e5e649bb50418c2db293f0990938dd5f8c8c2a7f与先前隔离“两PR合并基线”完全相同。于是从真实main的新隔离分支，将基线到已审查RC5 e04cb8a的最终差异作为补丁先check再index应用；结果树与e04cb8a精确相同，没有发生补丁冲突或引入未审查逻辑，也没有推送含“Evaluation only”字样的历史实验提交。后续只将App build号升14并更新真实合入记录，然后从clean HEAD完整重建。原PR6的旧独立测试依赖旧函数名，相关数组/对象及负例已保留在当前严格gameRootBinding测试；PR5测试接口也以当前双返回值及缺库诊断回归为准，不为机械保留旧接口而回退生产行为。原作者提交真实保留在main，而非仅以文案致谢替代。

build14构建、签名、本地包、日用更新和实机测试均须分别验收；build13的DMG不能冒充新sourceCommit产物。反馈补丁仍未纳入，系统helper/组件真实升级和全新CA交互、最终VM冷测依旧分开记录。此处不表示所有新增特性都只剩最后一项测试，也不表示发布Release或公证获准。


### 正式历史 build14 结果

源提交76192cefa6015c9ad763dbf3c96e50dd8d3261b7，sourceClean=true；与此前e04cb8a相比，功能源码完全一致，仅build号和真实合入记录变化。完整构建与全部自检通过，31个包内Mach-O部署目标审计、runtime hash审计和审计器symlink/empty-root负例均通过。通过正常安装入口更新日用App14并保留旧版备份；安装后及Terra实际烟测后原产品/legacy/shared runtime绑定哈希均不变。Terra确认主界面与两服原路径、旧helper对应更新提示正常，关于窗口仅显示rc5、不展示build号；实际build14及sourceCommit由Info/plist和build-provenance独立核验。退出后进程路径核查无启动器残留。

用日用14实际执行仅国际服preflight与launch，成功并由目标窗口截图确认当日公告；之后正常stop，仅结束隔离国际服，国服与IDV Login保留。该实测不覆盖全新CA交互、633真实系统升级或新VM冷装。

本地测试DMG最初attach遇到“资源暂时不可用”；只读核实残留设备确属本任务镜像后，正常卸载该设备、验证镜像校验和并重试只读挂载成功。未触碰其他VM磁盘，失败日志保留；随后签名树/来源复验、材料ZIP与统一哈希复算通过。DMG SHA-256为7a7e97d70147eb08deb2c1e422e2b5c2350c8900d33da305e27d609ad7aa4634；材料ZIP为49db4015237d3f8635ec8aa1a5572acda474d16689219c638242e09f21661bbc。未发布Release或公证。


## 可回收容量不能代替实际可写空间（2026-11-05）

Agent 安装实测中，前次隔离国际服任务已下载 14,570,838 bytes 后由测试取消；后续新候选的两次国际服、一次国服在零字节阶段收到核心终止状态 206。旧/新 Global 任务的官方基础清单除 fetchedAt 外语义一致（444 文件、17,602,266,736 bytes），任务参数除各自 prefix/目标/control 路径外相同。两版 supervisor 与 bootstrap 的 Mach-O 代码/只读数据及 Go 表一致，supervisor 都使用 Hardened Runtime；不能仅由文件签名哈希不同推断环境或下载逻辑回归。

只读宿主 API 同时测得实际可用容量 `15,782,969,344`、ImportantUsage 容量 `25,580,548,096` bytes。原管理器仅使用后者，因此能放行国际服本体加 2 GiB 余量的 `19,749,750,384` bytes，尽管实际可用容量不足。ImportantUsage 可能计入可回收空间，不能保证 Wine/厂商核心在检查或写文件前已回收。现预检要求实际容量可读取且非负；ImportantUsage 也有效时取两者较小值，否则使用实际容量。零容量保留为零，不回退到较大估算；实际容量缺失/无效则失败。仍沿用现有空间不足提示，不自动清理数据。合成回归覆盖这组真实数值、零、缺失/负值和较小 ImportantUsage。

206 的锁定核心静态依据：对 SHA-256 `5c11d3188d271c1df88d36d98bb440437d29e8a41c88dfd38602ce3c60c56f82` 的 PE，`download.PanicDiskFull` 在 `0x14046ba9e` 将 206 放入 r8d，并于 `0x14046bab1` 调用 errorCollector.Panic；但 `common.(*CompareManifest).TruncateAll` 在 `0x1404324a7` 同样传入 206，随后 Panic，关联消息为 `failed to create file`。ChunkWriter/FileBuilder 也有该码调用点。可用 Go 符号表与 LLVM 反汇编核查上述函数/地址；这说明它有文件/磁盘 I/O 路径，不等于 HTTP 206，也不能一概映射为磁盘满。

当前生产 supervisor 的 206 分支没有保留第三帧内容，因此前三次原任务记录只能证明收到了 206，无法追溯各自实际命中的 I/O 分支。随后在临时源码副本中仅增加有界、owner-only 的 206 帧保存，用同一失败 Global 任务和既有隔离 prefix 重放；三个核心文件先按锁定清单逐个验证，没有新增 prefix 或执行全量安装。监督器约 5.50 秒后以 206 失败，没有报告下载进度；捕获帧为 29 bytes，SHA-256 `018cf7151d01187bd4875fd605cf4137d9ca62c40ec8ad6a5b0230808dcaf3f7`，JSON 仅含 `NeedSpaceSize: 17719615180`。静态 GetDiskFullMsg 的字段名同为 NeedSpaceSize，与这次重放的空间报告一致，且所需量高于当时约 15.78 GB 实际可用空间。这确认了重放任务的空间不足报告，不将所有 206 或前三条无帧记录一概解释为同一原因。

调试捕获只留在临时副本和私人证据，不进入产品源码；生产 206 失败语义未改，也未新增猜测性错误映射。容量预检差异本身已修复，最终候选仍需在实际空间足够的隔离位置重新验收真实下载与取消。

### 精确空间失败的跨组件传播

锁定核心的真实206重放已提供单字段整数 `NeedSpaceSize`。supervisor只对这一精确形态（正Int64、无重复或额外字段、无尾随数据）返回 `download_disk_space_required` 与 `requiredBytes`；其他206仍为通用终止失败。原始第三帧不进入公开日志，仍只保留长度/hash元数据。类型化失败通过受限JSON从supervisor传到管理器，管理器给玩家可读空间提示；由Agent任务调用时额外发出相同稳定机器字段，普通GUI日志格式保持原行为。取消退出130不覆盖已收到的明确空间失败。Go覆盖真实帧数值、无效/模糊对象和IPC终止，Swift覆盖真实Process/pipe边界、错误退出与成功退出区别、任务UUID和未知消息不误分类；这些fixture不代替空间充足时的完整下载。

### macOS 15 的零值容量估计

新的干净macOS15虚拟机实测中，ImportantUsage与OpportunisticUsage均返回0，普通容量与NSFileSystemFreeSize同时为74,457,219,072字节，且无API错误。此前直接min会误拒绝。现仅用有效正数ImportantUsage约束普通实际容量，零/负/缺失估计回退普通容量；普通容量本身为0仍拒绝，普通容量缺失仍失败，不回退乐观可清理估计。管理器回归纳入这组真实数值，同时保留真实空间低于需求、可清理估计偏大及正数较小估计案例。最终包仍需该VM实际首装回归，不把build13结果当新行为。

## 外置位置导入后的 299 与错误来源（2026-11-05）

本轮只读观察到日用 RC5/build22 的国际服失败弹窗：具体提示为“另一个安装、导入或切换操作仍在进行，请稍后重试”，代码 `IDV-LAUNCH-299`。`ProductMutationLockError.busy` 在无法取得项目操作锁时产生该文本；GUI 分类器未覆盖它，落入自定义通用码 299。它不是网易下载核心、游戏或 HTTP 299。锁文件本身的存在不代表仍持锁，不能删锁文件当作修复；现有日志未记录当次持锁者和失败请求时间，因此不能确定具体是哪一个并行命令占锁。

独立迁移任务证据表明外置导入后游戏成功运行并完成约620MB补丁，随后再次到达亚洲服点击进入画面；本轮运行器日志也有成功激活窗口记录。检查时对应游戏进程已结束，未做关闭或重启操作。故能确定的是**有一次启动请求因操作锁忙碌被拒绝，299 对该请求是真实结果但分类过宽；它不证明之后启动的游戏失败**。GUI 的 `lastLaunchFailure` 保留至后续请求清理，并优先于空闲状态显示，不能当作实时游戏健康。

隔离候选为该明确提示添加 `IDV-LAUNCH-205`，状态区标为“上次启动请求未完成”，显示启动器来源、解释及操作建议；同一 GUI 请求成功时清理该产品遗留失败。没有取消互斥、自动重试、删除锁文件，也没有仅凭进程存在便把窗口验收判为成功。错误来源和可证实边界收录在随包 `currentRoute.md` 的“错误代码与排错”，与 `LaunchFailureClassifier`、`LoginStartupResult`、运行环境门和固定下载核心监督器对应。未公开的厂商状态不编造释义。

本轮候选构建、自检及真实首装验证结果待完成后补充；此前文档中的首装证据属于之前的候选，不能替代本轮验收。

验证补充：已在一次性HOME持有真实`product-manager.lock`后调用日用build22管理器的`launch --product global`，非零退出并返回现场相同忙碌提示；未建立产品记录或启动游戏。这是人为持锁的真实管理器复现，不是一次真实并发用户操作时序重放。对应时间段的限定系统日志查询未匹配到299、磁盘卸载或I/O错误，不能以日志缺失排除所有磁盘故障。新HOME真实安装在过长路径发生Wine `kernel32.dll / c0000135`，保留现场后改用短canonical HOME并复用已下载且校验的运行环境缓存；短路径安装仍在进行，尚未宣称完整链通过。

候选最终源码已通过进程边界/启动分类自检（含两种忙碌提示、未知错误299及预检默认201）和349个三语资源键检查，`git diff --check`通过。完整构建在/tmp隔离副本继续；尚未核对最终App包含最新源码，不把中途App当可交付物。运行中的真实首装使用日用build22（源码2623087），已进入核心state2，待完成后补记结果。没有替换日用App、推送、发布或公证。

### 运行时长路径受控对照（2026-11-05）

为区分游戏自定义目录与运行时路径，使用相同已校验运行时的独立外置副本、分别新建短HOME和独立prefix，仅运行 `wineboot -i`；不使用或结束日用游戏。按运行时根目录的UTF-8字节数计，181、201、211字节的三例退出0，216与221字节的两例均退出53并出现 `could not load kernel32.dll`、`c0000135`。把物理221字节目录通过35字节的短符号链接调用，仍退出53及同样错误。各例为一次观测；未证明精确临界值，也未定位 Wine 内部哪一处长度限制。不能仅凭现象认定它与此前267字符DLL路径故障同根因。

这次失败复现的是运行时路径而非游戏自定义目录路径。当前本机日用运行时根目录为177字节，落在已测成功样本之内；其他用户名、HOME位置、运行时版本、字符编码或磁盘布局不在该结论内。代码目前没有针对这一故障的可靠路径检测或修复，不应据此一刀切限制用户选择游戏位置。发行前需在隔离环境复验更多路径与不同版本，并确定安全可靠的运行时部署方案；短符号链接已被本次反例推翻，不能直接当修复。

新HOME独立首装使用已装build22及官方核心，完成 state 8、零退出、444文件和17,602,266,736字节清单复验；核心记录430次60秒读取超时检测，前期下载头约12分钟后继续，主体一度约20–40 MB/s，末段再度降速。外置副本排除下载核心缓存后再次用同一官方清单验证444文件、零差异，再在隔离HOME通过受支持的导入建立独立prefix；日用三份绑定文件哈希不变。外置客户端已报告启动成功且窗口激活日志出现，但此处不以进程或日志代替游戏画面：游戏日志有下载任务失败，热更新完成、公告及标题/登录页仍待可视验证。内置测试源按要求保留，不能视为已清理。

### 长路径后续：初始化跟踪及缓解实验

复用同一运行时副本，独立空prefix的模块/文件跟踪显示：失败样本的 system32 仅生成少量文件，后续 `wow64.dll` 和 `kernel32.dll` 加载失败；成功样本中 system32 有数百文件。`setupapi` 跟踪可见 `WineFakeDlls` 初始化，但没有直接打印底层失败调用。Wine 11.0 上游源码的 [FakeDlls 初始化](https://github.com/wine-mirror/wine/blob/wine-11.0/dlls/setupapi/install.c)及[内置DLL枚举](https://github.com/wine-mirror/wine/blob/wine-11.0/dlls/setupapi/fakedll.c)可帮助定位；当前实际运行时是厂商构建，不能假定与上游逐字节一致，也不能仅凭源码断言精确临界值。

一个独立长HOME样本（HOME 70字节、prefix 139字节）使用经现有manifest复验的同一运行时，实体目录缩短为145字节后，`wineboot -i` 退出0。相反，物理路径216字节的运行时仅额外设置指向短目录的 `WINEDLLPATH`，仍退出53并报相同 `kernel32.dll`；调试记录没有出现该短目录访问。这支持优先研究缩短运行时实体目录，而非把用户选的游戏目录强制改短，也不证明更极端HOME长度、升级迁移和实际游戏运行均已解决。

候选实现须同时保留旧版本目录和绑定兼容、验证完整受管文件、保证活动游戏不被中断、使中途崩溃可恢复，并覆盖已存在长目录的用户；仅改变新安装目录名不算完整修复。任何代码完成后仍须对应最终提交完成全量构建及隔离实机回归。

### Wine runtime path migration (candidate)

A controlled fixture initialized successfully with a 211-unit physical runtime path and failed at 216 with `kernel32.dll` / `c0000135`; a short symlink to the long physical directory did not fix it. These measurements do not establish a universal threshold. The runtime bootstrap now publishes a short hashed directory, while legacy full-version directories remain valid. The product manager prepares and verifies a separate copy, refuses to switch while a game is running, atomically switches `current`, and then saves the binding. The previous runtime is retained; an interrupted binding write can be retried. This does not restrict the user's chosen game directory. An exceptionally long home directory may still exceed the observed Wine boundary even with the compact name; the exact Wine cause is not established.
