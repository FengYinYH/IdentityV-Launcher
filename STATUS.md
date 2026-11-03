# 项目状态与接手入口

更新：2026-11-04。本页是本仓开发状态正本，不依赖聊天、Memoh 容器或仓外个人记忆。规划正本见 [开发计划](docs/developmentPlan.md)，调查证据见 [窗口与登录调查](docs/windowAndLoginInvestigation.md)。玩家说明仍用 README，已交付版本变化用 CHANGELOG。

## 接手顺序

1. 读 `AGENTS.md` → 本页 → [开发计划](docs/developmentPlan.md)。
2. 用 `git status --short`、`git diff` 核对实际工作树；下述快照不能代替实时检查。保留他人改动，不执行 reset/clean 来制造干净状态。
3. 从 [开发者指南](docs/developerGuide.md) 与 [项目地图](projectMap.md) 定位模块；按问题读专题，不从头重复调查。
4. 明确本次任务授权、交付条件、测试和安装影响，再实现。计划不是自动开工许可；本次仅整理文档，没有启动新 UI 或游戏功能施工。

## 2026-11-04 仓库核对快照

| 层次 | 已核对的状态 | 边界 |
| --- | --- | --- |
| 源码 HEAD | `9921da5`，2026-10-15，首次安装默认目录修复 | 没有在本轮查询远端 Release 或重新验收安装版 |
| RC3 基线 | `bbc03c0`；CHANGELOG 记录 2026-10-09 联系身份同步 | 不表示已安装 App 今天仍与它一致 |
| RC4 已有源码 | 默认目录不存在导致安装位置不可用的修复，见 [下载共链说明](docs/downloadCoreUnification.md) | 尚不能记为已发行；RC4 新 UI、窗口功能未在本轮实现 |
| 已有未提交源码 | `gameDownloader/supervisor.go` 将 `304` 纳入辅助协议状态，对应测试已有修改 | 来源任务/验收状态本轮未确认，禁止当作本轮已测试修复或覆盖 |
| 已有未提交规划 | CHANGELOG 增加“游戏多开（后续计划，非优先项）” | 保留，不抢占 RC4 窗口优先级 |
| 已有未提交二进制 | 两个 runner 模板中的启动 trampoline、辅助 dylib/程序与签名资源变化 | 很可能涉及构建产物，但归属/验证未确认，不擅自还原、提交或发布 |

本次修改只限交接文档及入口链接，不运行构建、不安装 App、不修改 runtime/prefix/服务、不停止游戏。未重新运行功能测试，不能把文档核对当作运行验收。

## 能力与待办分层

| 项目 | 状态 | 下一步/证据 |
| --- | --- | --- |
| macOS 国服/国际服下载、修复、启动管理；多语言 | 现有产品能力，源码/文档存在 | 实际环境和平台支持见 README，不能泛化为跨平台已支持 |
| 音频跟随系统默认设备 | RC2 已纳入；切换组合/耗时验证仍有限 | [音频边界](docs/audioDefaultDeviceFollowing.md)；气泡音是另一个未解决问题 |
| RC4 跨平台新 UI | 所有者明确方向，未落地；框架、各平台交付范围/矩阵待定 | [PLAN-UI](docs/developmentPlan.md#plan-ui跨平台新-ui) |
| 初始分辨率、默认居中、系统原生全屏、超屏确认 | 近期明确需求，未实现 | [PLAN-WINDOW](docs/developmentPlan.md#plan-window初始窗口) |
| 近期启动窗口变大/越屏 | 2026-10-18 冷启动复现过；最近首次触发未知 | [WIN-01](docs/windowAndLoginInvestigation.md#win-01启动窗口变大与越屏) |
| 账号登录面板比例偏小 | 用户长期报告；Mpay/WebView/CEF 静态证据已得；根因未定 | [LOGIN-01](docs/windowAndLoginInvestigation.md#login-01账号登录面板偏小) |
| idv-login 意外打开管理窗口 | 历史报告，10月18日称近期未再遇到，不等于修好 | [LOGIN-02](docs/windowAndLoginInvestigation.md#login-02意外打开管理窗口) |
| idv-login 页面不可达/功能缺失 | 与开窗独立；基础 ready 不证明业务健康 | [LOGIN-03](docs/windowAndLoginInvestigation.md#login-03功能健康与启动等待) |
| 可选预启动加速 | 设想/产品决策未定，未启用 | [PLAN-PRESTART](docs/developmentPlan.md#plan-prestart可选登录组件预启动) |
| 卡顿、语音气泡音、输入兼容 | 仍保留，不因本次规划取消，也不宣称新 UI 可解决 | [已知问题](docs/knownIssues.md)、[音频调查](docs/audioCapturePeriodicArtifact20260924.md) |

## 下一位开发者的可执行入口

- 做 RC4 UI/窗口：先确认跨平台范围/框架及未决默认值，按开发计划的验收矩阵实现；不能直接复活无界 System Events resize 或静默强改用户显示设置。
- 查登录功能：先区分 UI 自动出现、代理就绪、证书、管理页、真实登录；记录脱敏准确错误，不以隐藏窗口代替修复功能。
- 查面板缩放：先测登录容器/子进程 DPI 与实际尺寸，不先调全局 LogPixels/关闭 Retina。
- 做发行：先厘清当前未提交源码与二进制归属，从确切干净源码重建，签名、公证、升级/首装、真实游戏回归分别验收；本轮没有执行这些动作。

## 持续维护规则

每个任务结束或交接时，原位更新本页状态/验证时间、开发计划中的需求状态，以及相关调查的证据/反证；写清做了什么、没验证什么、下一步和具体阻塞。完成后把计划项标完成并给提交/测试依据，不靠追加相互冲突的“最新消息”。未决方向不因无人施工而自动降级或消失。

本页与开发计划是单一状态/规划入口；日期调查页只保留证据，不再成为另一份状态总表。可公开工程结论在仓内可独立理解，原始账号日志/截图/凭据和私人绝对路径留仓外。仓外旧档案如有更新应合并到这里后续接，不能要求新 Agent 先获得个人工作区或聊天访问权。