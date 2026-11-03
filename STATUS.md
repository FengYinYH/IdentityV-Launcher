# 项目状态

更新：2026-11-04。本页是状态正本，只放当前问题、方向、进度与规划；技术细节、证据和历史放到专题文档，不在这里累积。规划正本见 [开发计划](docs/developmentPlan.md)，详细核对快照与能力分层见 [状态明细](docs/statusDetails.md)，已交付变化见 [CHANGELOG](CHANGELOG.md)（[繁中](CHANGELOG.zh-Hant.md) / [English](CHANGELOG.en.md)）。

## 当前版本与进度

- 公开版：`1.0.0-rc.4`（2026-11-04），修复 #2 默认目录与 #3 辅助状态 `304`；App 与 DMG 已签名、公证并 staple。
- 上一版：`1.0.0-rc.3`（2026-10-09）。
- RC4 之后没有已决定范围。

## 当前要紧问题

| 问题 | 状态 | 入口 |
| --- | --- | --- |
| 国际服首装与中断续传 | #3 修复只有单元测试证据，真实下载待反馈者或本机实测 | [#3](https://github.com/FengYinYH/IdentityV-Launcher/issues/3) |
| 游戏鼠标捕捉丢失 | 2026-10-28 首次出现；指针可自由移动、`CGCursorIsVisible` 为真，Wine 约束未生效；未复现 | 待复现后记录 |
| 账号登录面板比例偏小 | 长期报告，根因未定 | [LOGIN-01](docs/windowAndLoginInvestigation.md#login-01账号登录面板偏小) |
| 启动窗口变大/越屏 | 10-18 冷启动复现过，最近触发未知 | [WIN-01](docs/windowAndLoginInvestigation.md#win-01启动窗口变大与越屏) |
| 启动延迟误报 `IDV-LAUNCH-203` | 固定 20 秒等待导致先报错、随后游戏仍启动 | [已知问题](docs/knownIssues.md) |
| 卡顿、语音气泡音 | 保留，未解决；与本版无关 | [已知问题](docs/knownIssues.md) |

启动器自身窗口固定为 680×420（显示下载进度时 530），由系统默认居中，已实现；游戏窗口的初始分辨率、默认居中、系统全屏与超屏确认仍属未实现需求（[PLAN-WINDOW](docs/developmentPlan.md#plan-window初始窗口)）。

## 当前方向

RC4 只做问题修复与文档整理，不引入新 UI 或窗口能力；发版后按实际反馈决定下一版范围。

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
