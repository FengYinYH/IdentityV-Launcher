# 状态明细

本页保存不适合放在 [STATUS](../STATUS.md) 的核对快照、能力分层和维护规则；STATUS 只保留当前状态。

## 2026-11-04 仓库核对快照

| 层次 | 已核对的状态 | 边界 |
| --- | --- | --- |
| 源码 HEAD | RC4 基于 `1f0fcb6`，含默认目录修复与 `304` 辅助状态修复 | 不表示已安装 App 与它一致 |
| RC3 基线 | `bbc03c0`；CHANGELOG 记录 2026-10-09 联系身份同步 | 公开版安装物需单独核对 |
| RC4 产物 | `1.0.0-rc.4` / build 8，App 与 DMG 已公证并 staple | 真实首装、续传与游戏回归未做 |
| 构建注意 | 构建会重新签名 `gameRunnerApp` 内 runner 模板，让工作树变脏；封包前需 `git restore` 还原到 HEAD | 许可材料生成器会拒绝脏工作树 |

## 能力与待办分层

| 项目 | 状态 | 下一步/证据 |
| --- | --- | --- |
| macOS 国服/国际服下载、修复、启动管理；多语言 | 现有产品能力 | 平台支持见 README，不能泛化为跨平台已支持 |
| 音频跟随系统默认设备 | RC2 起纳入；切换组合/耗时验证有限 | [音频边界](audioDefaultDeviceFollowing.md)；气泡音是独立问题 |
| 启动器窗口 | 固定 680×420（下载时 530），系统默认居中 | `playerLauncherApp/Sources/ProductLauncherView.swift`、`IdentityVToolboxApp.swift` |
| 游戏窗口初始分辨率/居中/全屏 | 未实现 | [PLAN-WINDOW](developmentPlan.md#plan-window初始窗口) |
| idv-login 意外开窗 | 10-18 后未再遇到，不等于修好 | [LOGIN-02](windowAndLoginInvestigation.md#login-02意外打开管理窗口) |
| idv-login 页面不可达/功能缺失 | 与开窗独立；ready 不证明业务健康 | [LOGIN-03](windowAndLoginInvestigation.md#login-03功能健康与启动等待) |

## 持续维护规则

任务结束或交接时，原位更新 STATUS 的状态与验证时间、开发计划的需求状态，以及相关调查的证据/反证；写清做了什么、没验证什么、下一步与具体阻塞。详细内容进本页或专题文档，不回流到 STATUS。未决方向不因无人施工自动降级。可公开工程结论在仓内独立可读；原始账号日志、截图、凭据与私人路径留在仓外。
