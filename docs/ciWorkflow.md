# CI 能力与协作建议

## 当前整理方案（2026-11-07）

已对照GitHub真实Actions记录和分支定义：先前一共6个工作流、16次运行，只有1次通用Core checks，其余15次属于5类临时实验。公开主线缺少这些工作流及实验工具，Actions列表显示的定义来自临时ci分支，不能把它们当作主线持续检查。RC5已经公开，早期段落的“尚未运行/待发布”仅代表其记录时间。

可核查的代表记录：[Core checks通过](https://github.com/FengYinYH/IdentityV-Launcher/actions/runs/41976918009)、[首装实验通过](https://github.com/FengYinYH/IdentityV-Launcher/actions/runs/41991243123)、[国际服有限启动观察通过](https://github.com/FengYinYH/IdentityV-Launcher/actions/runs/42002240555)、[图形能力探测通过](https://github.com/FengYinYH/IdentityV-Launcher/actions/runs/42014562448)、[公告目标未达失败](https://github.com/FengYinYH/IdentityV-Launcher/actions/runs/42024255079)。最后一个明确在Require verified restart window and announcement candidate步骤失败；前面的绿色不证明公告、账号登录或对局通过。

国际服的本次产品验收边界由所有者于11/7重申：完成官方热更新、按提示重开并到公告页即为目标；受账号与地区条件限制，不要求进入大厅或对局。Hosted公告实验的截图已到公告页，但当时OCR漏检，门禁仍失败；报告的`hotUpdateVerified=false`及公告背后40.1%进度的含义尚未得到确认，因此不能据公告截图补称热更新全流程验收通过。后续公告及其后画面优先本地核验，不为同一截图再做托管全量下载。

先前定义在不同临时分支触发，以9760550、a8d27ba等候选作为业务基线，并校验其祖先关系及后续CI工具变更白名单；实际构建使用checkout HEAD，并非只编译旧候选。运行42024255079的`candidateCommit=a8d27ba67b813b9a9c44d7ec99db3861e3012268`，`checkoutCommit=01cdb307a2bcb51aced37c8d99fb92472ee88261`，后者与GitHub run head一致。隔离实验尚未收束成长期入口，旧RC命名与后来发行代码的关系需以实际源码身份判断。历史运行保留原记录，不改写为新测试的结果。

本轮迁回经过验证的五个实验工具，整理为两个按能力命名的可维护入口：

| 入口 | 触发与作用 | 验证边界 |
| --- | --- | --- |
| `.github/workflows/checks.yml`：Core checks | PR、main/integration push及手动，执行本项目合约、Go test/vet、本地化和实验监督器测试；官方metadata联网仅手动选择 | 不公证、不发布、不全量下载游戏，不证明真实GPU/账号体验 |
| `.github/workflows/integration.yml`：Installation and graphics experiments | 仅手动选择graphics/install/launch/announcement及产品；默认graphics，不下载游戏；运行名/报告按本次提交标识 | 选择安装才全量下载，选择启动/公告才观察窗口；公告候选仍需人工可视确认 |

两个入口都使用调用时确切checkout提交，不在工作流中写死营销版本或旧RC业务提交。build和源码身份由App provenance/报告记录，发布流程以后引用与最终提交匹配的结果。既有实验保留隔离临时HOME、磁盘/耗时截止、账号/协议界面停止、受管退出和有界脱敏产物策略，不在日用Mac执行全量实验。

当前这些整理是本地源码变更，尚未推送、触发新的GitHub任务或停用远端历史定义。迁回的10项监督器单元测试通过、两份YAML用系统解析器通过；真实托管运行需在最终确切提交推送后另验。后续合入时由新入口替代临时ci分支，保留旧分支提交可追溯性；不因为重命名而再跑整套大下载。

## 公告实验证据保全与OCR窄修正（2026-11-07）

已只读核对并下载[运行42024255079](https://github.com/FengYinYH/IdentityV-Launcher/actions/runs/42024255079)的`announcement-observation-global`制品（artifact ID `13416702734`）：4,261,712 bytes，API到期时间`2026-11-08T13:05:47Z`，原始ZIP SHA256为`88a5e06ed8539452009905cbdfa899a81b5e3ac082b8acdfaeb73a436a97e13e`，与GitHub API digest一致。原ZIP、来源元数据、未提交补丁及离线验证结果保存在仓外仅所有者可访问的证据存储；截图和原始日志不纳入Git。解压前检查了路径越界、符号链接和总展开大小，未执行制品内容。

原报告记录`restartAttempted=true`、`coreVerifiedRestartWindow=true`、`preRestartUpdatePrompt=true`，而`announcementVerified=false`、`hotUpdateVerified=false`，观察以时间上限停止。最后截图可见公告正文，证实当时存在OCR漏检；历史run的Require verified restart window and announcement candidate门禁失败保持不变。

按内容逐项比对原CI工作树与当前迁入工具：`ciFullInstall.py`、`ciGraphicsProbe.swift`、`installCIOCR.command`及10项监督器测试逐字节一致，只有`ciScreenClassifier.swift`缺少未提交的公告识别修正。窄合入组合正文标记（称呼、游戏名称、维护文本同时存在）、一次灰度OCR回退，继续保留更新页排除、登录/协议停止与候选人工确认边界。新增正文识别及缺少标记/更新页反例自检；没有更改实际HEAD来源记录、磁盘/耗时预算、默认graphics或下载策略。

本地10项监督器测试通过，Swift分类器编译及自检通过；使用既有Tesseract英文模型、明确游戏窗口裁剪，保全的最后一张公告截图离线得到`announcementCandidate=true`。本机仅有英文模型，本轮未重新验证中文OCR；既有CPU配置在新SDK上有弃用警告，编译仍通过。这是离线观测修正，未触发新CI、不证明Hosted重跑或热更新完成，也不触碰账号、协议、输入或游戏资源。

## 以下为2026-11-05分阶段调查与实验历史

调查日期 2026-11-05。GitHub API 实际读取：仓库公开、默认分支 main，Actions workflows 0、runs 0、registered self-hosted runners 0。当前分支在本次新增之前也没有 .github/workflows。未更改远端设置、推送、合并或发布；不能声称现有 CI 绿灯已覆盖候选。

## 适合本项目的方式

采用 GitHub 协作 + 本地实机验收。保留 PR 原作者提交，先将贡献 PR 与 RC5 修复调和到集成分支，按最终树核对现有测试，再逐个小 PR 进入集成分支。不要为了“先合了再修”把尚未验证的整合作为稳定主线。已有的原历史保留实验只证明树可调和，实际合并前还须复核最新 refs 与用户修改。

每波变更先做模块测试和托管 CI，在本机确认影响下载、安装、权限或游戏运行的行为；工作流绿灯后仍可继续多波改动，不必每次 release。候选稳定后锁定 commit，从干净源码重建最终包，再做来源、签名、公证、安装升级、冷机首装和真实游戏验收，最后单独 release。普通 PR 无需公证或接入发行凭据；GitHub 上改代码也仍有本地 checkout 和真实 App 测试，不是把环境差异交给用户发现。

本轮新增本地可审阅的 `.github/workflows/checks.yml`：PR、main/integration push 或手动触发，macos-15 arm64，跑 ProductManager/Agent 合约、六个 Go 模块 test/vet、三语资源检查；30 分钟 timeout，同 ref 更新取消旧检查，不涉及发行。仅工作流草案进入本地树，未在 GitHub 执行，首跑通过后再把真实 check 名加入分支规则。随后只读API确认Actions已启用、allowed_actions=all、默认workflow token为read且不可批准PR；外部PR审批、分支保护与账号预算仍未核验，此轮未修改设置。

## 托管机器能做与不能证明的事

| 检查 | 托管 CI | 本地/真实机器 |
| --- | --- | --- |
| Swift 合约、语言资源、路径/状态 fixture | macOS SDK 上可做；新增工作流覆盖 | 初次 CI 仍要验证工具链差异 |
| 六个 Go 模块 test/vet | macOS 上可做，含部分合成映像/挂载测试 | 实际挂载权限差异失败时查环境，不跳过 |
| 完整原生 App 编译、包结构/Mach-O 审计、ad-hoc 签名 | 可扩展第二阶段；当前完整脚本依赖 runner 模板、Go、补丁构建与签名配置，未在托管执行 | 本轮完整构建单独记录；Developer ID/公证是不同门 |
| 真实官方 CDN 请求、小范围下载 | 可做联网 smoke，网络地域/上游限制可能不同 | 本地真实 CDN、代理与失败恢复仍需覆盖 |
| 17.6 GB 全量游戏 + runtime + 临时事务 | 标准 runner 公布 14 GB SSD 资源，不适合作为默认全量验收；不能由此推断某次具体 free space | 独立大盘/专用 runner，空间与时长实测 |
| CLI 任务状态/错误/取消 | fixture 可自动化；真实安装需隔离资料目录 | 最终包的真实断线/续传/修复仍需实测 |
| 原生弹窗、TCC/麦克风、Rosetta 首次流程、登录证书、游戏 GPU/输入/音频 | 托管无已验证玩家会话，绿灯不能证明体验；更不能依赖 VM Metal 给游戏验收背书 | 在相应系统的真实 Mac/用户会话验收 |
| macOS14 兼容 | macos-14 在 2026-11-02 已退役，不能靠该标签测试 | 若继续支持须自有14环境与真实GPU；当前DXMT重建问题另见专题 |

## 当前官方资源与费用

标准公开仓库 macOS arm64 为 M1 3 CPU / 7 GB RAM / 14 GB SSD；`macos-15`、`macos-26` 是当前版本标签，`macos-latest` 会迁移，不等于最新 OS。Intel 标签为 `macos-15-intel`/`macos-26-intel`，4 CPU / 14 GB RAM / 14 GB SSD。编译 target arm64 和可执行测试优先固定 arm64 标签。arm64 托管不支持嵌套虚拟化，不能在其中再启动 macOS14 VM；无固定 UDID，macOS larger 也没有静态 IP/私网能力。出处：[GitHub-hosted runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)。

公开仓库标准 hosted runner 使用免费；larger runner 即使公开仓库也计费，且可用性与 Team/Enterprise 组织方案有关。私有仓库按方案共享 compute 额度/超额价格结算；制品/缓存另有额度，不把“公开标准计算免费”外推成任何大包存储都无限免费。账号方案与账单未读取，不提供虚构预算。出处：[Actions billing](https://docs.github.com/billing/managing-billing-for-github-actions/about-billing-for-github-actions)。

托管单 job 最长 6 小时，自托管最长 5 天；Free/Pro/Team 标准并发总额不同，但 macOS 通常为 5 个并发，实际账号能力须查配置。工作流的30分钟是本项目选择，不是平台上限。出处：[Actions limits](https://docs.github.com/en/actions/reference/limits)。上游 CDN 的访问质量/下载速率没有项目级保证，需首跑实测；GitHub 网络与原用户网络不是同一环境。

macos-14/macOS14 larger 标签已于11月2日退役，当前不能推荐它作为新工作流目标。出处：[官方退役公告](https://github.blog/changelog/2026-10-01-github-actions-macos-14-runner-image-retirement/)。本项目是否继续14支持由所有者决策，与部署 target 能否编译分开。

## 自托管的用途与边界

专用 Mac 能固定系统、接真实 GPU、大盘和真实 CDN 环境，适合 nightly/手动可信集成测试；不建议把日用游戏 Mac 直接连到公开 fork PR 自动执行。自托管默认不保证每次干净，需要维护工具链、资料目录、进程/挂载清理和 runner 更新；Actions 本身不收 self-hosted compute 费，硬件/电网/维护仍自付。每次只对已审阅的确切 commit 手动执行可信测试，使用独立测试用户/硬件与隔离游戏目录；真实 macOS 用户权限仍按系统授权。这是公开代码执行的 CI 环境边界，不是给产品 Agent 添加通用只读限制。出处：[Self-hosted runners](https://docs.github.com/en/actions/concepts/runners/self-hosted-runners)、[Secure use](https://docs.github.com/en/actions/reference/security/secure-use)。

当前没有注册 runner，也没有测试过 GitHub 到本机的连接，不能写成已部署。先启用标准合约 CI 并积累耗时/失败数据，再决定是否值得添加专用自托管全量测试，避免为了自动化引入比本地开发更大的维护负担。

## 首次托管 CI 可行性实验（2026-11-05追加）

所有者希望直接尝试CI以减少手工VM处理。现成方案仍是GitHub托管`macos-15` arm64：服务自动准备/回收VM，不需要用户安装虚拟机或注册持久runner。工作流增加runner的系统/架构/内存/CPU/磁盘/Xcode探测；临时`ci/**`分支push可自动触发合约job，以及独立的15分钟`official-network` job。后者使用真实ProductManager解析两服官方安装器地址，不下载installer/game载荷；普通PR/main不自动跑此联网job，手动dispatch也可选择执行当前整份工作流。不是Wine游戏启动或全量下载实验。

本地非破坏性实验：最终候选真实CLI的隔离HOME状态/错误/随包文档一致性通过；经相同核心调用两服`resolve-download`，均成功解析到允许的`gdl.netease.com`/`gdl.easebar.com`域及预期安装器文件名，没有下载或安装载荷。六模块test与完整App构建通过，工作流新增的全六模块vet单独核验。这些是当前Mac上的实证，不冒充GitHub托管网络/资源已通过。网络smoke脚本为`productManager/tests/officialNetworkSmoke.test.py`，模块自检加`--network-smoke`显式启用；默认自检仍不请求官方网络。

首次真实远端实验尚未执行。需要的具体远端动作仅为：把审阅后的确切候选提交推送到该仓库一个新分支`ci/rc5-agent-smoke-20261105`，其push事件即启动本分支工作流；不推main、不合PR、不release、不改仓库设置、不添加持久runner。随后只读查询该分支run并watch结果。由于目前默认分支没有此工作流，不应只对未注册的workflow_dispatch发调用并声称已执行；用ci分支的push触发解决这个首次引入问题。推送前由主任务报告具体branch与commit并按现有授权执行，此子任务没有推送。

结果应先回答：真实托管架构/Xcode/free-space是多少、合约能否全部通过、官方resolver能否访问及耗时。标准14GB公布资源不足以预先保证17.6GB游戏+runtime+事务目录，因此本轮不尝试全量安装，不用小metadata请求宣称真实游戏下载成功。若还要全量/续传/修复，需要先测空间，再选择有足够盘的larger runner（账号可用性/费用另核）或专用自托管Mac；图形、系统权限与账号交互仍不能由这两个job证明。CI流程调整不作为RC5阻挡项，接口与随包文档仍必须进入RC5。

追加核验结果：只读settings API确认`enabled=true`、`allowed_actions=all`、`default_workflow_permissions=read`、`can_approve_pull_request_reviews=false`。精确的CI smoke入口`./productManager/selfTest.command --network-smoke`在本地隔离HOME完整执行通过，包括编译、原核心自检、Agent状态/错误/文档协议和两服真实官方resolver；全六模块vet通过。带随包文档的完整App也重新构建及签名树/31枚Mach-O检查通过；仍无托管run，不能将这些本地结果称作GitHub执行结果。

## 首次远端推送受 GitHub OAuth scope 阻挡

按所有者追加授权，已审查确切候选`7ab30569339d1cadebb75cdf9052e02e783ada08`相对当时公开main `91aadb15adda663efbea6e847afa3421111385a6`新增的历史/文件：165个新增blob版本、约3.9MB，密钥/私有路径模式扫描与新增文件人工复核未发现应保留私下的材料。既有路径示例、脱敏测试伪密钥和上游构建路径不是本次新增私有数据。查询时PR5/6已合并、开放PR为0，目标新分支不存在；独立CI分支不会修改这些合并。

随后只向`refs/heads/ci/rc5-agent-smoke-20261105`尝试推送上述确切提交，GitHub服务端明确拒绝：`refusing to allow an OAuth App to create or update workflow .github/workflows/checks.yml without workflow scope`。现有认证只有repo/read:org/gist，缺workflow。拒绝后只读复核：目标远端分支仍不存在、workflows为0、该分支run列表为空。没有改main、设置、PR或release，也没有重试同一凭据或换身份绕过。

因此远端CI尚未运行，不能报告托管结果。下一步需要账号本人为当前GitHub连接补授workflow scope（例如在可信本机交互式`gh auth refresh -h github.com -s workflow`并完成GitHub授权），再按新的确切提交/分支重新审查并推送；本轮未执行认证变更。此阻挡来自GitHub认证权限，不是产品CLI只读限制，也不改变RC5须包含Agent接口/文档而CI流程调整不阻挡发行的约定。本地合约、完整构建及真实resolver结果仍有效，但不代替GitHub运行。
