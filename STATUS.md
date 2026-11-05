# 项目状态

更新：2026-11-05。本页是状态正本，只放当前问题、方向、进度与规划；技术细节、证据和历史放到专题文档，不在这里累积。规划正本见 [开发计划](docs/developmentPlan.md)，详细核对快照与能力分层见 [状态明细](docs/statusDetails.md)，已交付变化见 [CHANGELOG](CHANGELOG.md)（简中、繁中、English）。

## 当前版本与进度

- 公开版：`1.0.0-rc.4`（2026-11-04），修复 #2 默认目录与 #3 辅助状态 `304`；App 与 DMG 已签名、公证并 staple。
- 上一版：`1.0.0-rc.3`（2026-10-09）。
- 本机候选：`1.0.0-rc.5` / build 9，修复下载监督器的 Wine 动态库路径和终止性辅助状态；既有候选已完成国际服安装，启动暴露产品记录格式读取错误。本轮修复已通过完整构建与两服预检，并更新日用 App；国际服已从日用入口启动，完成约 3.5 GB 官方首启热更新，确认更新提示后从同一入口重开，显示国际服公告及标题/登录场景；账号登录和大厅/对局未验，见[根因与证据](docs/downloadCoreUnification.md#rc5-国际服安装完成后启动预检失败2026-11-05)。

## 当前要紧问题

| 问题 | 状态 | 入口 |
| --- | --- | --- |
| 国际服安装与启动 | 本机已完成安装→日用入口启动→官方首启热更新→重开→国际服公告及标题/登录场景；账号登录、大厅/对局及中断续传仍待独立实测 | [根因与验证](docs/downloadCoreUnification.md#rc5-国际服安装完成后启动预检失败2026-11-05) |
| 仅国际服启动后误报 299（#6 附带） | 当前 launch/restart 仍依赖旧国服 legacyBinding，建议按产品 runtime 修复；尚未改代码 | [审查与方案](docs/downloadCoreUnification.md#两种下载修法的取舍与-6-复核2026-11-05) |
| IDV Login 全新状态首次授权失败（#7） | 报告日志与上游/helper 顺序吻合；需可恢复授权流程，macOS 26 真实交互待验 | [来源与审查](docs/idvLoginSourceAudit.md#issue-7system-job-首次-ca-授权失败2026-11-05-审查) |
| 游戏鼠标捕捉丢失 | 2026-10-28 首次出现；指针可自由移动、`CGCursorIsVisible` 为真，Wine 约束未生效；未复现 | 待复现后记录 |
| 账号登录面板比例偏小 | 长期报告，根因未定 | [LOGIN-01](docs/windowAndLoginInvestigation.md#login-01账号登录面板偏小) |
| 启动窗口变大/越屏 | 10-18 冷启动复现过，最近触发未知 | [WIN-01](docs/windowAndLoginInvestigation.md#win-01启动窗口变大与越屏) |
| 启动延迟误报 `IDV-LAUNCH-203` | 固定 20 秒等待导致先报错、随后游戏仍启动 | [已知问题](docs/knownIssues.md) |
| 卡顿、语音气泡音 | 保留，未解决；与本版无关 | [已知问题](docs/knownIssues.md) |

启动器自身窗口固定为 680×420（显示下载进度时 530），由系统默认居中，已实现；游戏窗口的初始分辨率、默认居中、系统全屏与超屏确认仍属未实现需求（[PLAN-WINDOW](docs/developmentPlan.md#plan-window初始窗口)）。

PR #5（`c15101a`）已独立审查：模块测试、额外路径边界及 Hardened Runtime/GnuTLS 探针通过；与本机 RC5 重复且存在整合冲突，尚未整合。该提交的全量首装/启动未验，辅助消息语义仍需样本，见[审查记录](docs/downloadCoreUnification.md#pr-5-与本机-rc5-的整合审查2026-11-05)。

本轮整合候选：RC5 build 10，采用 PR #5 的窄路径恢复、按产品确认窗口、首次 CA 有界恢复、自定义安装与只读导入检测。最终源码 a9bc18f 的完整签名构建通过；隔离国际服 17,602,266,736 bytes 安装、暂停/恢复、取消后续传、整树复验与无国服记录预检通过。444 文件只读检测与单文件损坏检测通过；尚未启动新测试游戏或更新日用版，原游戏进程保持运行。已有纯本地测试 DMG，Apple 公证因外部提交授权被自动审批拒绝，待明确确认。

## 当前方向

当前完成 RC5 下载与国际服启动链修复及本机验收，不引入新 UI 或窗口能力。已授权的本机开发按[开发闭环](AGENTS.md)更新日用版、重启实测并收尾；公开发版按独立发行检查和已有授权执行。

## 未来规划

- 跨平台新 UI（[PLAN-UI](docs/developmentPlan.md#plan-ui跨平台新-ui)）
- 初始窗口设置：分辨率、默认居中、系统原生全屏、超屏确认（[PLAN-WINDOW](docs/developmentPlan.md#plan-window初始窗口)）
- 登录健康与耗时（[PLAN-LOGIN](docs/developmentPlan.md#plan-login登录问题与健康)）
- 可选登录组件预启动（[PLAN-PRESTART](docs/developmentPlan.md#plan-prestart可选登录组件预启动)）
- 游戏多开（后续计划，非优先）
- Metal FX、自定义安装路径、发现已有游戏

## 接手入口

1. 读 `AGENTS.md` → 本页 → [开发计划](docs/developmentPlan.md)。
2. 用 `git status --short`、`git diff` 核对实际工作树；不要用 reset/clean 制造干净状态。
3. 用 [开发者指南](docs/developerGuide.md) 与 [项目地图](projectMap.md) 定位模块，按问题读专题。
4. 明确本次授权、交付条件、测试与安装影响后再动手。
