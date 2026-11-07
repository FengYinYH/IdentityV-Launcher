# 关于与版本更新窗口

## 目的和实现

2026-11-07 的 UI 调整恢复菜单栏原生“关于”窗口的真实构建号，并统一“版本与更新”结果窗口的文字。原来的关于面板显式传空 build，无法区分相同营销版本的开发构建；现在 `LauncherRelease.buildNumber` 读取当前 App 的 `CFBundleVersion`，通过标准 About 面板的 `.version` 交给 AppKit 排成“版本（build）”。营销版本仍取 `IdentityVReleaseVersion`，保留 RC 标签，不用源码常量伪造本次构建号。

`LauncherUpdateView` 是正式更新结果 sheet 与视觉预览共用的 SwiftUI 内容。标题、版本明细、错误和下载安装进度文案使用 `NSFont.smallSystemFontSize`、regular，以系统关于窗口版本行的小号常规字为目标；最终字体外观仍需原生实测。取消、安装、下载进度及交互锁仍绑定原业务状态。

窗口宽高也属于本次要求。整合负责人实测原生关于窗口 AX 外框为 **284×191 逻辑点**（含标题栏）。`LauncherPanelGeometry.frameSize` 集中保存此几何契约，关于面板和更新窗口复用：关于仍使用 AppKit 原内容，显示后将其 NSPanel 外框设为该尺寸；更新 sheet 与隔离预览按各自窗口的 `contentRect(forFrameRect:)` 计算内容区域，因此不猜标题栏高度或误把内容宽当外框宽。更新图标为 32 点，按钮使用 small 控件，较长文案只在固定区域滚动，不扩张主窗。最终包仍需 AX 复测两窗口尺寸、build 行及三语可读性；系统最小尺寸约束或后续 AppKit 排版变化应以实测反馈修订共享契约。未更改检查、缓存、限流、下载、签名或替换的语义。

## 隔离原生视觉预览

维护者可直接启动已构建的候选 App 可执行文件：

```sh
"<候选App>/Contents/MacOS/IdentityVLauncher" --preview-launcher-update --preview-language zh-Hans
"<候选App>/Contents/MacOS/IdentityVLauncher" --preview-launcher-update --preview-language zh-Hant
"<候选App>/Contents/MacOS/IdentityVLauncher" --preview-launcher-update --preview-language en
```

省略 `--preview-language` 使用当前语言；显式语言仅接受以上三项，不写语言偏好。参数必须从 `--preview-launcher-update` 开始，无效参数返回 64。应直接创建候选可执行文件的新进程，避免 LaunchServices 复用日用 App 的现有进程。预览显示当前 App 的实际营销版本和固定视觉示例目标 `1.0.0`。

该入口在 `IdentityVToolboxApp.main()` 前分流，不创建 `ToolboxViewModel`、不运行偏好迁移、状态刷新、卡死监视、网络检查、缓存或安装器，只显示独立原生父窗口和同一份更新内容 sheet。“仅预览，不会下载或安装更新。”使用三语资源；“更新”禁用且没有业务回调，“取消”结束预览进程。真实 UI 没有预览按钮、参数提示或开发说明，预览不修改真实更新结果。

这是纯视觉入口，无新增 Agent 业务命令，也没有将模拟版本交给现有 Agent 更新接口。正式业务继续由共享更新核心及原有 Agent 命令承担。

## 编译输入与检查

- 新增 `playerLauncherApp/Sources/LauncherUpdateView.swift`；主 App 既有 `Sources/*.swift` 编译输入自动包含它。单独编译 `ProductLauncherView.swift` 的外部工具需要补上此文件。
- 新增 `playerLauncherApp/Tests/LauncherUpdatePreviewSelfTest.swift`；既有 `Tests/updaterSelfTest.command` 已加入真实 `ToolboxModels.swift`、`LauncherLanguage.swift`、`LauncherUpdateView.swift` 的独立编译及无窗口测试。该检查覆盖显式入口、三语参数、拒绝非法参数和无操作 fixture。
- 三语新增两个视觉资源键，共 359 个一致的键；资源检查通过。
- `Tests/updaterSelfTest.command` 全套离线回归通过：预览、checker、假 App 替换/回退、回执身份、系统条件、活动锁、挂载失败清理、超时及结果分类。没有打开窗口或替换真实 App。
- 主 App 全部 Sources 与原有 sharedDiagnostics 输入的 Swift 类型检查通过（macOS 14 target、Swift 5）。编译器报告既有 `ToolboxViewModel.swift` 卡死倒计时 Timer 回调的 actor 隔离告警，本次未修改该段。

## 验收边界

源码和无窗口检查不能替代原生界面验收。此次执行角色没有启动 GUI、全 App 构建、替换日用 App 或控制桌面。整合负责人须从最终候选展示关于面板真实 build 和三语更新预览，确认字体、换行、按钮状态及用户亲眼看见“检测到新版本”窗口；该项仍待统一桌面验收。正式更新下载、Gatekeeper、同址替换和回执链沿用原专题的独立验收状态，视觉预览不证明这些业务链已通过。
