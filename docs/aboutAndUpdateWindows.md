# 关于与版本更新窗口

## 目的和实现

2026-11-07 的 UI 调整恢复菜单栏原生“关于”窗口的真实构建号，并统一“版本与更新”结果窗口。原来的关于面板显式传空 build，无法区分同一营销版本的开发构建；现在 `LauncherRelease.buildNumber` 读取当前 App 的 `CFBundleVersion`，通过标准 About 面板的 `.version` 交给 AppKit 排成“版本（build）”。营销版本仍取 `IdentityVReleaseVersion`，保留 RC 标签。

最新需求按原生关于窗口的排版、字号、对齐和间距设计更新窗口，宽284；新增两按钮在下方自然延伸高度。此前固定同高191、13/12字号和压缩间距的要求已被覆盖，不再作为验收条件。关于继续完全使用 AppKit 原生布局，移除显示后强制 setFrame 的逻辑；正式更新和隔离预览共用 `LauncherUpdateWindowController` 与独立 `NSPanel`，没有假父窗或 sheet。

2026-11-07 通过公开 `orderFrontStandardAboutPanel` 有意展示标准关于，再读取其 NSView 树的真实 frame、NSFont.pointSize 和 traits，得到以下基准。AX 焦点外框可能外扩1点，不能由 AX 高度推断字体：

| 对象 | 实际 NSView 外框坐标（逻辑点，从窗口左上起） | 实际字体 |
| --- | --- | --- |
| 原生关于窗口 | 284×191，内容284×159，chrome32 | 系统原生 |
| 图标 | (110,40,64,64)，对应AX(109,39,66,66) | — |
| 名称/更新标题 | (6,112,272,17) | 系统14号粗体 |
| 版本/当前版本 | (6,137,272,13) | 系统10号常规 |
| 版权/最新版本 | (8,158,268,13) | 系统10号常规 |

`LauncherAboutMetrics` 保存这些实测基准。更新使用单独的原生 NSTextField 标题和各行正文，保持标题至首行8点间距、两版本行21点起始间距；长标题按文本实际高度顺序向下延伸，普通信息不滚动。原生 regular 系统按钮右靠相邻，跟在正文下方，保留20点下边距；按钮高度使用 intrinsicContentSize。只有超长错误正文超过160点时才滚动。图标位置始终从窗口顶部基准换算，不因窗口变长下移。

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

该入口在 `IdentityVToolboxApp.main()` 前分流，不创建 `ToolboxViewModel`、不迁移偏好、不刷新状态、不运行卡死监视、网络检查、缓存或安装器。预览直接 render 正式面板 controller，不增加额外预览说明文案；“更新”按钮按真实可用态显示，controller action 拒绝预览安装，原生按钮点击和程序直接调用均不会进入安装回调。取消或关闭结束独立预览进程。正常用户流程没有预览入口或开发说明，真实更新结果不接受模拟注入。

## 编译输入与验证

`playerLauncherApp/Sources/LauncherUpdateView.swift` 包含共享尺寸、状态、原生 controller、SwiftUI 状态桥和隔离预览。主 App 既有 `Sources/*.swift` 自动纳入，未增加全局构建脚本输入。`Tests/LauncherUpdatePreviewSelfTest.swift` 通过既有 `Tests/updaterSelfTest.command` 编译真实 Models、Language 和该文件。

自检覆盖三语参数、非法参数、预览原生按钮点击与直接 action 均拒绝安装、同一 panel 身份跨进度/失败保留、下载取消与不可取消状态、普通结果关闭及自然增高。隐藏原生控件检查14粗体/10常规、图标和标题实测位置、版本两行21点间距、按钮原生尺寸、长标题增高与长错误滚动；不调用 show、不下载、不替换 App。最终隐藏布局实测普通中文外框284×235、英文两行标题284×252，正文两行各13点、起始相隔21点，均无滚动；系统regular按钮固有高度24点，中文按钮行外框y=191，底边距20点。长错误使用160点正文上限，总高361点并滚动。此前两条额外预览文案资源已移除，三语共357个一致键。

先前更新模块完整离线回归通过 checker、假 App 替换/回退、回执身份、系统条件、活动锁、挂载失败清理、超时及结果分类。前一呈现版本已通过主 App 全 Sources 类型检查（既有卡死 Timer 回调 actor 告警未改）。本轮按实际 About 基准调整后，仅编译共享 controller、Models/Language 和隐藏面板自检，以及最小预览壳；生命周期/布局、三语资源与补丁格式检查通过，最终全 App 编译由整合负责人执行。另已独立编译由同一 controller、Models/Language 和最小 `@main` 组成的临时预览 App，携带真实 rc5/build27 元数据、图标和三语资源，使用隔离 bundle ID，不含业务管理器。该执行角色未自行显示GUI；后续整合实测已打开自然增高版，AX外框284×235、图标66×66且相对窗口(109,39)，标题和版本行与原生About位置一致。负责人已从干净源码`070c833`完整构建build27，全部既有自检、签名/部署目标审计通过，替换日用App并正常重启；主窗口、实际进程路径和CLI就绪分支复验通过。临时预览已关闭，后续从日用入口查看；不能把此前sheet的展示当作本版通过。

## 待验边界

完整构建、日用安装、正常启动与自然增高版实际展示已完成；三语资源与隐藏中英文/长错误布局覆盖已通过。后续已从日用build27菜单实际打开About：外框284×191、版本行`版本1.0.0-rc.5 (27)`，再从主窗口真实“版本与更新”入口得到“已经是最新版”外框284×193，并以“好的”正常关闭。实际新版可用态此前由同一controller隔离展示，外框284×235；无下载、安装或真实结果注入。公开更新下载、Gatekeeper、同址替换和回执链仍按原专题独立验收；视觉预览不证明正式更新链通过。
