# CI 能力与协作建议

调查日期 2026-11-05。GitHub API 实际读取：仓库公开、默认分支 main，Actions workflows 0、runs 0、registered self-hosted runners 0。当前分支在本次新增之前也没有 .github/workflows。未更改远端设置、推送、合并或发布；不能声称现有 CI 绿灯已覆盖候选。

## 适合本项目的方式

采用 GitHub 协作 + 本地实机验收。保留 PR 原作者提交，先将贡献 PR 与 RC5 修复调和到集成分支，按最终树核对现有测试，再逐个小 PR 进入集成分支。不要为了“先合了再修”把尚未验证的整合作为稳定主线。已有的原历史保留实验只证明树可调和，实际合并前还须复核最新 refs 与用户修改。

每波变更先做模块测试和托管 CI，在本机确认影响下载、安装、权限或游戏运行的行为；工作流绿灯后仍可继续多波改动，不必每次 release。候选稳定后锁定 commit，从干净源码重建最终包，再做来源、签名、公证、安装升级、冷机首装和真实游戏验收，最后单独 release。普通 PR 无需公证或接入发行凭据；GitHub 上改代码也仍有本地 checkout 和真实 App 测试，不是把环境差异交给用户发现。

本轮新增本地可审阅的 `.github/workflows/checks.yml`：PR、main/integration push 或手动触发，macos-15 arm64，跑 ProductManager/Agent 合约、六个 Go 模块 test/vet、三语资源检查；30 分钟 timeout，同 ref 更新取消旧检查，不涉及发行。仅工作流草案进入本地树，未在 GitHub 执行，首跑通过后再把真实 check 名加入分支规则。是否启用 Actions、外部 PR 审批、分支保护、账号预算尚未验证；此轮未修改设置。

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
