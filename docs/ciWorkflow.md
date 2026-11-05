> 本轮RC5整合只纳入Agent接口、文档与本地验证入口，CI workflow文件保留在独立候选，未借此绕过GitHub workflow scope限制。以下为原调查与候选记录。

# CI 能力与协作建议

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

## 完整首装驱动已准备，候选冻结待确认

在独立克隆中基于整合检查点9e5ff6e准备full-install.yml、ciFullInstall.py及无网络单元测试，未改共享候选代码。五项测试和YAML解析通过，非Actions本机调用会在创建安装目录前拒绝。报告每5秒采样剩余空间，记录最小可用/观测增量峰值和阶段转换；不将采样峰值称为绝对瞬时峰值。构建与前置错误保留最多4KiB经过过滤的尾部，不导出其他原始日志。

工作流保留FINAL_CANDIDATE_NOT_FROZEN占位符，未推送、未开始载荷下载。准备期间发现共享整合树存在ProductManager修改，随后提交为19a27b7（容量估计为零时采用普通可用容量）；旧9e5ff6e因此不应被当作最终首装候选。须由主协调任务明确最终冻结提交，将CI专用增量安全应用到该提交之上，并审查所有新增公开对象后再推测试分支。既有7ab3056绿灯仍只是旧候选smoke。

后续取得干净整合检查点97605502a685ae765c213fee4d1620ea4348d79e（build20），已将专用CI增量调和至该检查点并填入准确候选SHA。完整构建使用既有IDENTITYV_TEST_HEADLESS=1测试入口，仅推迟原生UI自检，生产确认不变；新跨架构会话自检要求Rosetta，因此先以5秒有界Intel true探针检查，缺少即停，不自动安装或接受许可。本轮测试仅对该build20业务源码有效，不声称后来不同提交或Release已完成验收。

首次托管尝试run41989909876在构建阶段失败：Rosetta探针exit0，工作流驱动测试通过，但Xcode16.4无法编译新SwiftUI的glassEffect（ProductLauncherView.swift:234）；尚未解析基础清单或下载游戏/runtime。约96秒后失败，初始46,338,703,360 bytes可用，最低46,176,464,896 bytes，5秒采样增量峰值162,238,464 bytes。此为工具链失败，不是下载或首装失败。官方同一镜像清单列有Xcode26.3，因此仅修改CI的DEVELOPER_DIR选用该已装工具链，保持9760550业务源码不变；没有自动接受Apple许可或上传载荷。


The Xcode 26.3 retry (run 41990357203) also stopped before downloads: the frozen candidate's Timer closure triggers actor-isolation diagnostics in that compiler. The next experiment selects GitHub's standard `xcode-27` arm64 image (macOS 27), matching the locally validated compiler major version; it changes no application source. GitHub announced this image as generally available on 2026-10-15: https://github.blog/changelog/2026-10-15-xcode-27-runner-image-generally-available/ . This experiment cannot establish macOS 15 runtime compatibility.


## build20 托管真实首装通过（最终结果）

2026-11-05，run [41991243123](https://github.com/FengYinYH/IdentityV-Launcher/actions/runs/41991243123) 最终 success。冻结业务源码 `97605502a685ae765c213fee4d1620ea4348d79e`，CI checkout `0abaf4044ae3d0297caa77037554aa11109c4103`；差异仅为本专题的 CI/文档七文件，无应用源码改动。使用标准 `xcode-27` arm64 托管镜像 `20261026.0314.1`，实际 macOS 27.0.1 / Xcode 27.1 / Swift 6.4；不是 macOS 15 或 14 的运行验证。前两次旧工具链失败保留上文，不需要为了此次实验修改 Timer 或其他业务源码。

完整 job 11分43秒；驱动673.29秒，其中完整构建325.07秒、运行前提5.16秒、真实清单4.41秒、Agent 首装336.91秒。初始可用37,672,861,696 bytes（35.09GiB）；安装前36,679,831,552 bytes（34.16GiB），超过门槛35,433,480,192 bytes（33GiB）；最低观测可用18,311,401,472 bytes（17.05GiB），相对初始观测增量峰值19,361,460,224 bytes（18.03GiB）。采样间隔5秒，不能将这些数字称为绝对瞬时峰值。

这次真实执行国服新用户目录安装，清单 `v3_4220_229300afaa11f1da1aa4af7379c2a648`，439文件，共17,045,687,138 bytes，清单SHA256 `7c297995238fc8bc8fe3ad7f79eb0f8a088298c458ea4ca30542fcdd085a498c`。任务 `730cbf24-c60b-43f7-af85-e473865e90f8`；runtime/preparing/downloading/verifying/publishing/completed 均被观测到，终态 succeeded，任务和子进程exit0。监督脚本随后验证产品ready、版本一致、目标包含dwrg.exe、安装事务和staging已清理；基础清单全量验证由成功安装核心执行。阶段首次观测（距首装开始秒）：runtime5.11、preparing25.36、downloading142.22、verifying326.64、publishing/completed336.91。这是采样转换时间，不是各阶段精确耗时。

只上传约2KiB结构化result.json（保留3天），无游戏、runtime、prefix或原始构建日志上传；本地保存了结果及GitHub标准job日志。没有启动游戏、账号登录、原生UI/权限弹窗、取消续传/修复或旧macOS验证。本次是adhoc源码构建，不能代替最终签名DMG、公证和Gatekeeper验收。没有修改main、仓库设置或发布Release。

建议采用混合流程：在本地完成开发与快速检查，测试分支/PR以CI执行合约和构建；安装链路变更或候选验收时才选择性运行这类真实首装，避免每个提交重复17GB下载。集成分支可以分批推进，通过PR检查后再合并；Release前仍需真实Mac完成原生UI、权限、实际游戏启动和最终签名包验证。单次首装绿灯不能替代这些检查，也不应要求每次迭代手工建VM。此工作流目前仅绑定独立实验分支，正式PR触发策略仍需另行整合，不会自动修改主分支流程。


## 托管游戏启动与公告页实验：先验图形能力

所有者希望在真实首装后继续验证启动、热更新和公告页。此前首装runner已销毁，不能接着读取同一游戏目录；重新首装意味着再下载约17GB。先用独立 `ci/rc5-game-launch-20261105` 分支的 `game-launch.yml` 执行5分钟上限的图形探针，检查Metal设备及真实命令提交、桌面display和既有屏幕录制授权，不请求权限、不模拟输入、不下载游戏。`ciGraphicsProbe.swift` 只输出能力JSON，不能据此宣称游戏启动或公告页通过。

若Metal和display可用，再准备全新首装后的有界启动/热更新观察；只调用现有Agent启动接口，不登录、不改游戏二进制、不绕过运行限制。保留6GiB磁盘底线、有限观察时间和仅结果/必要游戏画面证据。进程存在只能算进程里程碑，热更新需要明确日志或文件证据，公告页必须有可靠视觉验收。若图形能力缺失，先停止昂贵重下载并报告阻碍；不把此环境限制归为启动器失败。


图形实证：run [41993684822](https://github.com/FengYinYH/IdentityV-Launcher/actions/runs/41993684822)，checkout1e4cc48，45秒成功。Metal为Apple Paravirtual device，真实命令completed；1个1024x768 display，截屏权限已具备，没有申请新授权或发送输入。此前成功首装的runner已结束，不能接着使用它的目录。

按所有者追加要求，准备 `server-install.yml` 在新隔离分支上串行运行mainland、global两项，max-parallel=1，前一个runner结束自动回收后再建下一个，无本机删除动作。每项仍冻结9760550业务源码、全新HOME/目录、原空间门槛与6GiB底线及安装两小时时限；安装成功后仅调用既有Agent launch观察最多480秒，每15秒记录进程数、任务状态和空间。最多四张临时runner游戏画面，保留三天；最终通过既有Agent stop结束本产品，随后runner回收。启动任务失败且无游戏进程则30秒后提前停止。未发送点击/按键、不登录、不操作付费/对局、未修改游戏或绕过运行限制。图形探针通过不能保证D3DMetal、游戏或热更新能运行。

报告独立记录安装成功和launchObservation；CI任务完成不等于公告页通过。coreVerifiedGameWindow只采用原核心进程/窗口验证结果；hotUpdateVerified/announcementVerified保持false直到后续日志/画面得到明确人工或Agent验收。安装前后文件计数/总字节变化仅是辅助事实，不能单独证明热更新成功。仅上传结果JSON、图形能力JSON及至多四张游戏截图；不上传游戏/prefix/runtime。失败日志尾部经过长度限制及敏感字段过滤。

[GitHub附加产品条款](https://docs.github.com/en/site-policy/github-terms/github-terms-for-additional-products-and-features)将托管Actions限制于关联软件项目的生产、测试、部署或发布，并禁止负担与用户收益不成比例的活动。对启动器安装/启动链路执行有限次数候选验收与该项目测试直接相关；这是基于条款的适用判断，并非GitHub对具体用量预先批准或保证不受限制。这里不配置周期循环、CDN、游戏下载分发或游戏托管；两服各一次、串行、限时、仅短期元数据/画面。如遇上游或GitHub限流/拒绝则停下报告，不换账号或规避限制。标准公开仓库runner免费不代表任意使用无限制。


两服首轮run41994337182都在构建测试阶段失败，均未解析基础清单或下载游戏。相同失败为TestAuxiliaryFramesDoNotExtendIdleDeadline的2001诊断断言，driver分别266.08/270.37秒，非游戏启动/热更新结果。本机该项连续五次通过，冷托管环境两次失败；夹具先发送常规进度，然后持续约3.2秒辅助帧，原300ms窗口易受调度影响。仅将该测试idle窗口改为1500ms并保留超时及2001断言，仍短于持续辅助流：若辅助帧错误重置deadline，夹具先结束，测试仍失败。生产超时和业务源码保持9760550；精确checkout另行记录，差异白名单显式增加此测试文件，不把测试调整称为字节一致源码。修正后仅再执行一次两服验收，不无界重试。

重跑41996080216在构建早期主动取消：复核发现扩展启动观察后，顶层gameLaunched仍保留旧首装默认false。修正为仅当核心启动任务成功且验证窗口时设true，另外记录gameLaunchAttempted；不以请求接收或进程计数冒充成功。取消时尚未进入游戏载荷下载，随后使用同一生产源码与测试修正启动最终实验。


run41996455990（checkout53deb64）的国服job21分9秒成功：构建323.90秒、首装389.17秒、启动观察491.56秒（包含停止收尾），基础439文件/17,045,687,138字节。核心启动任务succeeded/exit0并验证窗口；四图中第2/3/4图可读热更新1.44%/14.04%/21.65%，最后760.373MB/3511.446MB。确认真实游戏渲染和热更新开始/推进，八分钟观察结束时尚未完成，未出现公告页。文件总量从17,050,282,218增至17,962,645,239字节仅作辅助。截图留短期附件/私人证据目录，不提交仓库。

该次采样gameProcessCount=0是观察器漏匹配Windows反斜杠路径，不能作为无进程证据；核心和截图均已独立证明游戏。stopError=Extra data来自错误地把agent run的JSONL当单JSON，日志记录wine exited143，说明实际停止已发生。后续观察器采用与核心一致的路径分隔符，并使用start/task读取停止终态；8项监督脚本测试通过。首个国际服job6分22秒停止在manifest阶段：构建325.31秒，未安装或启动。

真实缺陷定位：ProductManager的resolve-manifest接受global参数，却调用resolveDirectManifest；国际服catalog没有国服directDownload，故必然失败。改用既有officialContentManifest共享分流入口，一行生产修正，复用GlobalAdapter及身份转换；增加真正CLI的私有adapter夹具回归，验证global输出和身份不匹配拒绝，不联网、不绕过校验。之后仅重跑global，不重复国服。新国际服验证以这个修复候选的精确SHA为基线，不能冒称9760550未经修改就已通过。

超时夹具根因补充：前10个完全相同进度帧间隔25ms，至少250ms；生产按设计不把重复无进展帧用于重置idle timer，所以原300ms只留下约50ms理想余量给第一个辅助帧。1500ms仍显著短于3.2s辅助流，保留语义断言且为调度留足余量；不是简单删除失败断言或修改生产超时。


国际服修复候选a8d27ba的run42000828792完整构建354.50秒、前提5.14秒、真实共享清单1.03秒均成功，得到444文件/17,602,266,736 bytes，版本v3_1278_3c43b662809efa2461d0bf3f51d56cb7。尚未安装：安装前34,725,064,704 bytes（32.34GiB），低于旧CI额外17GiB预留给出的34GiB门槛。不是产品空间错误或下载失败，也未启动游戏。

依据国服实测基础数据之外约2GiB的占用，后续CI预留调整为14GiB：运行时/prefix/临时数据4GiB、热更新4GiB、硬停止底线6GiB，向上取整基础清单后门槛31GiB。产品自身D+2GiB检查与监督6GiB停止规则不变；不删工具链、不购买larger runner。采用同一a8d27ba生产源码，仅再执行国际服，不重复国服；此前国际服尝试均未开始载荷下载。空间不足或上游拒绝仍明确失败，不作无界重试。space-preflight阶段单独输出，避免把预算拒绝称作metadata解析失败。


### 32.34GiB余量的测量归属

run42000828792驱动开始（已完成checkout、setup-go和图形检查，尚未完整App构建）可用37,359,611,904 bytes=34.7938GiB；构建/前提/清单后、游戏安装前34,725,064,704 bytes=32.3402GiB，阶段净差2,634,547,200 bytes=2.4536GiB。两数是df式卷余量采样，不是du式项目独占占用；没有对Appbundle、Go cache、Swift module cache或预装工具作分目录测量，不能将全部差额或初始已用空间归因于本项目。setup-go本轮另下载Go1.27.3，发生在驱动initialFree之前。镜像清单明确有Xcode/SDK、多个语言版本、浏览器和预缓存工具，版本为xcode-27-arm64/20261026.0314.1；各自占多少GiB没有实测。

此前run41991243123曾记录卷总150GiB、当时35GiB可用，但不是42000828792的卷总量实测，不作该次精确磁盘分解。未来已有验收任务可在构建前/后增加df -k和特定目录du -sk：RUNNER_TEMP下build、go env GOCACHE/GOMODCACHE、选定Swift module cache、工作树和目标Appbundle；初始仅补预装目录如/Applications、/Library/Developer的只读统计，并区分包含关系避免重复加总。此需求不另触发CI、不删除预装工具，也不部署风栈/BWH。


## 两服实验最终结论（已结束，不追加任务）

国际服run [42002240555](https://github.com/FengYinYH/IdentityV-Launcher/actions/runs/42002240555) 最终success，job33分24秒（09:25:26–09:58:50 UTC），checkout `3d91b973401283ed736ef9ad33ad7ae98197c98a`，生产修复基线 `a8d27ba67b813b9a9c44d7ec99db3861e3012268`。完整构建483.40秒，首装922.33秒（15分22秒），启动观察/收尾490.13秒。444文件、17,602,266,736 bytes基础清单全量核心校验及ready/版本/事务清理通过，安装任务与子进程exit0；启动任务约46.48秒首次观测为succeeded并验证窗口，停止任务也succeeded。真实进程从15.32秒起连续采样为1，修正后的进程匹配和停止记录均得到此次验证。

四张原始截图已逐张查看：第1张为启动准备中的桌面，第2/3/4张可读IdentityV游戏窗口，Downloading patches进度5.09% → 18.42% → 26.64%，最后约997MB/3744MB。因此确认Metal环境下的实际客户端画面、热更新开始和持续推进；八分钟观察截止时尚未完成补丁，没有公告页。国服此前同样停在热更新21.65%，不是公告页通过。两个原始result.json均保留hotUpdateVerified=false、announcementVerified=false；旁路视觉验收记录区分“开始/推进”和“完成”，不改写原始附件。没有账号登录、点击/按键、对局或限制绕过，不将window/process里程碑冒充公告页。

本次镜像xcode-27-arm64/20261026.0314.1，macOS27.0.1，Region明确westus、Cloud为MacCloud；图形探针实证Apple Paravirtual device、Metal命令completed、1024x768桌面及已有截屏权限。只证明该托管虚拟图形环境，不能替代物理GPU性能、macOS14/15、Gatekeeper/最终签名包及干净权限弹窗验收；也没有记录出口IP/路径或CDN机房，不推断具体网络位置。

国际服初始34.898GiB，安装前34.031GiB，含启动观察采样的最低15.272GiB、相对初始观测额外峰值19.626GiB。构建/首装5秒采样、启动观察15秒采样，不是绝对瞬时峰值。此前32.3402GiB来自另一次42000828792，其构建前34.7938GiB，净差2.4536GiB；两次都没有分目录du数据，不能以这些差额替代项目产物/缓存独占占用。

两服均调用自身停止接口后结束临时job，runner按托管机制回收；没有本机删除游戏、修改日用App、main/设置/Release或上传游戏/runtime/prefix。附件只有限量结果/已过滤日志尾/四张临时游戏画面，保留3天；原始结果和截图本地留私人证据，未提交截图。风栈缓存及BWH不再准备、部署或测试，本任务此前也没有部署这些服务，不撤销用户既有配置或数据。所有本轮运行已终态，不再触发重复测试。

交接：独立产品补丁global-manifest-routing-fix.patch只含一行分流修复、实际CLI正/负夹具和接口文档；另有supervisor-fixture-timing-fix.patch仅修改测试时序，两者曾在共享整合树0eef2de上git apply --check通过，未修改共享树。完整CI实验增量另行提供，正式整合时应更新冻结candidate到整合后的真实SHA，不直接照抄旧实验SHA；不把整合后不同源码视为已经获得同一次验收。
