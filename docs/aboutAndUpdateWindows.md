# 关于与版本更新窗口

## 目的和实现

2026-11-07 的 UI 调整恢复菜单栏原生“关于”窗口的真实构建号，并统一“版本与更新”结果窗口。原来的关于面板显式传空 build，无法区分同一营销版本的开发构建；现在 `LauncherRelease.buildNumber` 读取当前 App 的 `CFBundleVersion`，通过标准 About 面板的 `.version` 交给 AppKit 排成“版本（build）”。营销版本仍取 `IdentityVReleaseVersion`，保留 RC 标签。

窗口宽高属于本次要求。整合负责人实测原生关于窗口 AX 外框为 **284×191 逻辑点**（含标题栏），`LauncherPanelGeometry.frameSize` 集中保存关于和更新窗口的几何契约。关于保持 AppKit 标准内容；正式更新和隔离预览都直接使用同一个 `LauncherUpdateWindowController` 和独立 `NSPanel`，没有附着主窗的 sheet，也没有预览父窗。

初版曾使用 SwiftUI sheet、假预览父窗和填满剩余高度的滚动区。实际展示产生额外灰窗口、白色气泡及大片留白，用户明确认为与项目风格不一致，因此已移除该实现。当前面板按关于的实际图标 AX 外框 **66×66**、相对窗口位置 `(109,39)` 校准。原生预览表明 `NSImageView` 的 AX 焦点外框比 view 向外扩 1 点，因此使用64×64的view，当前chrome32时内容坐标为 `(110,8)`，使实际AX尺寸/位置与关于一致，而不把隐藏view几何当作最终AX验收。最新用户反馈以可读性优先：标题为 **13 号粗体**，正文和按钮为 **12 号常规字**，覆盖此前全常规小字要求。按钮相邻靠右。普通标题、两行版本和按钮在 284×191 内完整显示而不滚动，只有长错误超出区域才滚动，不撑大主窗口。

## 正式状态和关闭流程

`ProductLauncherView` 的 `LauncherUpdateWindowPresenter` 保留同一 controller，读取原 `ToolboxViewModel` 的标题、消息、可用版本、下载安装进度和可取消状态。每次更新只 render 原生内容，不重新创建窗口或重复抢焦点：

- 用户确认更新仍调用原 `installLauncherUpdate()`，检查、缓存、下载、签名、替换及重启业务不变。
- 下载阶段取消仍调用原 `cancelLauncherUpdate()`，等待原异步任务取消与清理后由 `showsLauncherUpdateResult=false` 隐藏面板。
- 进入不可取消的准备替换阶段后，取消按钮隐藏、关闭按钮禁用；进程退出仍由原更新事务触发。
- 失败和清理错误保持面板并显示原消息；“好的”、普通结果关闭按钮和“取消”关闭原展示状态，不修改真实 release 结果。
- 主视图拆除时隐藏面板，与原主窗 sheet 的 UI 生命周期一致；不会取消或替代后台业务任务。

这是呈现层调整，没有新增 Agent 业务操作，也没有第二套下载或安装逻辑。

## 隔离原生视觉预览

直接启动候选 App 可执行文件的新进程，避免 LaunchServices 复用日用进程：

```sh
"<候选App>/Contents/MacOS/IdentityVLauncher" --preview-launcher-update --preview-language zh-Hans
"<候选App>/Contents/MacOS/IdentityVLauncher" --preview-launcher-update --preview-language zh-Hant
"<候选App>/Contents/MacOS/IdentityVLauncher" --preview-launcher-update --preview-language en
```

省略 `--preview-language` 使用当前语言；显式语言只接受以上三项，不写偏好，无效预览参数返回 64。预览展示当前 App 实际营销版本和固定视觉示例目标 `1.0.0`。

该入口在 `IdentityVToolboxApp.main()` 前分流，不创建 `ToolboxViewModel`、不迁移偏好、不刷新状态、不运行卡死监视、网络检查、缓存或安装器。预览直接 render 正式面板 controller，不增加额外预览说明文案；“更新”原生按钮禁用，controller action 同时拒绝预览安装，即使程序直接调用也不会进入安装回调。取消或关闭结束独立预览进程。正常用户流程没有预览入口或开发说明，真实更新结果不接受模拟注入。

## 编译输入与验证

`playerLauncherApp/Sources/LauncherUpdateView.swift` 包含共享尺寸、状态、原生 controller、SwiftUI 状态桥和隔离预览。主 App 既有 `Sources/*.swift` 自动纳入，未增加全局构建脚本输入。`Tests/LauncherUpdatePreviewSelfTest.swift` 通过既有 `Tests/updaterSelfTest.command` 编译真实 Models、Language 和该文件。

自检覆盖三语参数、非法参数、预览 action 拒绝、同一 panel 身份跨进度/失败保留、下载取消与不可取消状态、普通结果关闭行为及外框几何。测试创建隐藏 panel 检查原生生命周期，不调用 show、不下载、不替换 App。最新布局实测：外框 284×191、chrome32，图标AX外扩修正后view内容坐标 `(110,8,64,64)`；普通中英文正文区域高度 47 点且无需滚动，按钮位于内容 y=131、高20点，互距8点，长错误使用51点区域并启用滚动。自检同时核对标题13粗体、正文/按钮12常规及不存在预览说明。已移除不再使用的两条预览文案资源，三语共 357 个一致键。

先前更新模块完整离线回归通过 checker、假 App 替换/回退、回执身份、系统条件、活动锁、挂载失败清理、超时及结果分类。本次原生重做后，主 App 全 Sources 类型检查、隐藏面板生命周期/布局自检、三语资源与补丁格式检查通过；类型检查仍报告原有卡死 Timer 回调 actor 告警，未改该业务段。另已独立编译由同一 controller、Models/Language 和最小 `@main` 组成的临时预览 App，携带真实 rc5/build27 元数据、图标和三语资源，使用隔离 bundle ID，不含业务管理器。该产物供负责人直接展示，未自行启动 GUI；不能把此前 sheet 的展示当成新版通过。

## 待验边界

整合负责人负责最终完整构建、安装与桌面操作，执行角色仅源码、独立主可执行文件编译和隐藏面板自检。最终候选仍需验证关于真实 build 行、About/Update 的 AX 外框、三语短信息完整可见和长错误滚动，并由用户亲眼看见新版原生窗口。公开更新下载、Gatekeeper、同址替换和回执链仍按原专题独立验收；视觉预览不证明正式更新链通过。
