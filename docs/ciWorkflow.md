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
