# 窗口与登录调查：证据、边界及接续方法

调查：2026-10-18；整理入本仓：2026-11-04。适用源码基线 `9921da5`；下面动态数值是当时样本，不是11月4日再次测量。源码对应位置于11月4日定点复核。本文合并此前窗口、账号面板及 idv-login 报告的有效工程信息，去掉个人绝对路径/账号现场与无法核验的历史引用；独立阅读本仓即可接续，不依赖容器文件或私人档案。

当前状态见 [STATUS](../STATUS.md)，需求与验收见 [开发计划](developmentPlan.md)。所有问题均未在本次文档整理中修复。

## WIN-01：启动窗口变大与越屏

### 现象与复现

用户报告最近几天才明显变大，而非三个月前开始。2026-10-18 经授权通过已安装 ProductManager 的 `restart --product mainland` 重启一次，保持登录组件运行，只读观察90秒：

| 阶段 | 渲染像素 | macOS 窗口外框/位置（逻辑点） |
| --- | --- | --- |
| 初始化 | 1334×750 | 出现后667×403，X342/Y224，基本居中 |
| 约4秒后 | 2704×1698，接着2708×1698 | 1354×849，X仍342，Y29 |
| 稳定 | 2708×1642客户区 | 外框仍1354×849 |

该显示器为1352×878逻辑点，2x backing。大窗右边缘1696，超屏344点。启动前另一次测量外框相同、X56，越屏约58点。当前渲染/客户区符合2x映射，**这次不能归为已证明的Retina 1:1失效**。当时游戏保存 `graph.resolution=[2704,1698]`、`full_screen=off`。谁/何时首次写入该大小未知。

### 源码依据

`gameRunnerApp/IdentityV-Mac.app/Contents/MacOS/launchIdentityVRunner`：
- `IDENTITYV_USE_VIRTUAL_DESKTOP` 默认0（约266行）；`IDENTITYV_DESKTOP_SIZE` 默认1920x1080（约268行）只属于可选 Wine virtual desktop，**不保证普通direct窗口每次1080p**。
- `refresh_registry_contract`（约983行起）写 `RetinaMode=Y` 及 dwrg.exe 的 `~ HIGHDPIAWARE`（约1003/1050行）；标记匹配可跳过导入，静态marker不等于动态状态已测量。
- `reset_prefix_if_display_changed`（约1208行）比较显示签名；启动主路径约1566行调用，随后清理所选prefix旧进程。
- 普通游戏路径直接运行 dwrg.exe，激活器负责窗口激活，不能把激活成功当作尺寸/居中校正成功。

### 历史与反证边界

旧私人快照支持曾有一次性 `IDENTITYV_INITIAL_WINDOW_SIZE=1920x1080` 的 System Events 调整尝试，也曾记录找不到窗口、无界等待、性能排查时禁用等失败；8月24→31归档快照之间该函数被去除，产品仓9月23基线之前已经没有它。某版旧函数位置是 `{80,80}`，**不支持把它说成可靠居中**。早期7月显示模式切换后旧Wine缓存导致1:1大窗是另一类历史问题，不能拿来判定本次原因。

此前口头整理中出现的“7月8–13日可靠实现/删除居中”、不存在的专篇文件名和 `TODO.md`/`4da6c4a` 引用没有得到当前仓库可复核支持，**不作为本仓结论继承**。用户关于暂缓自定义的历史动机也已撤回为不确定记忆。当前“默认居中”来自10月18日明确产品决策，而非依赖上述历史叙述。

近期轮转日志曾见1080p与2704×1698两种路径，部分会话后来又切换尺寸；未保存可靠统一索引/显示环境和交互时间线，不能圈定最近触发日期。渲染轨迹本身不等于当时外框/位置，不用旧日志推翻用户体验。

### 接续验证

同时记录渲染像素、外框/客户区、显示器逻辑/物理模式、时间及启动入口；区分初始引擎尺寸与加载保存设置后的尺寸。对照同一环境的冷/暖启动、保存配置与显示变化，避免一次改变DPI、游戏分辨率和窗口策略。不要直接复活无界System Events脚本或无限强制resize。

## LOGIN-01：账号登录面板偏小

用户报告游戏和其他控件比例正常，账号登录面板约为Windows的1/4；尚未测量是面积还是边长，也未建立可比的Windows缩放基线。

### 静态证据（2026-10-18 游戏样本）

安装树的模块名引用：`NtUniSdkMpay.dll` → `mpay.dll` → `webview_support_helper.dll`；`webviewsupport.cef904430/` 含browser.dll、webview_support_browser.exe、render.exe、libcef.dll及100%/200%资源。

| 文件 | PE版本 | VS_FIXEDFILEINFO偏移 |
| --- | --- | --- |
| mpay.dll | 4.10.0.370 | 0x6c2978 |
| NtUniSdkMpay.dll | 4.10.0.0 | 0x455cc8 |
| NtUniSdkNgWebview.dll | 1.5.11.0 | 0x388718 |
| webview_support_helper.dll | 2.3.5.0 | 0x530c8 |
| webviewsupport.cef904430/browser.dll | 2.3.5.0 | 0xf74c8 |
| webviewsupport.cef904430/libcef.dll | 90.5.5.0 | 0x92a5dc0 |

mpay.dll 的静态字符串：
- 0x4974c8/0x4974e0：`layout/webview_cef.xml` / `layout/webview.xml`；
- 0x4975e0：`set current DPI for Mpay as [%d]`；
- 0x49b014：`__mpay_option_force_zoom`；0x49b28c：`actual use DPI [%d]`；
- 0x49b61c：`NGWEBVIEW_DEVICE_SCALE_FACTOR`；0x4a753c：`force_device_scale_factor`；
- 还同时有cef67与默认cef90内核字符串。browser.dll含`force-device-scale-factor`及EnableHighDPISupport相关符号。

这是独立Mpay/WebView/CEF显示链路的充分静态线索，**不是当次登录页确实使用CEF90、具体DPI错误或可配置环境变量的证明**。偏移只适用于上述样本；游戏更新后须核对版本/字节。

当时prefix为RetinaMode=Y、LogPixels=96；AppCompat HIGHDPIAWARE明确只设置dwrg.exe。不能因此认定子进程一定DPI-unaware（可能自行声明manifest/API）；SDK又有独立zoom接口。未取得动态DPI/zoom/容器归属，原始登录日志白名单投影没有相关命中，不等于没用该组件。

### 接续验证/不要做什么

先安全测量外框、内容、文字/二维码比例和窗口PID/模块归属，在同一屏幕缩放下与Windows对照；只记录白名单current/actual DPI、zoom、device scale。若有合适网页诊断入口，可只取devicePixelRatio、viewport与容器尺寸，不抓账号DOM/存储/网络正文。未获证据前不调全局LogPixels、不关闭Retina，不把内部选项名猜作环境变量。

Mpay面板与 idv-login 的网络/代理功能是不同层，不能用隐藏后者管理窗口修复前者比例。

## LOGIN-02：意外打开管理窗口

用户称前几天出现、近期未再遇到；历史触发、准确URL和进程链未知，状态为未复现/未定位，不是已修复。

`privilegedHelpers/idv-login-job.sh`（约78–101行）的ProgramArguments只有binary，不含 --open-ui/--uri。固定上游源码 [3642748](https://github.com/KKeygen/idv-login/tree/3642748dcf82c326ddb5cb657714be9a0885d7fc) 的 main.py:1657–1688 支持URI/显示UI信号，uimgr.py:832–855的compat管理界面是QtWebEngine加载 `https://localhost/_idv-login/index`；非compat为`idvlogin://app/_idv-login/index`。创建UIManager不等于主动显示。

不能直接认定是外部浏览器或某个高端口后台。下次收集去掉query/token的准确scheme/host/path/port、事件时间、入口与错误类型，区分连接拒绝、TLS、404、静态页/桥接与业务失败。不要收集完整URI或账号正文。

## LOGIN-03：功能健康与启动等待

### 当前ready覆盖范围

`privilegedHelpers/start-idv-login.sh:190–208` 查受管进程、精确hosts、受管进程树持有127.0.0.1:443；约407行写readiness confirmed之后仍确认CA。没有证明管理页、资源、Qt网页桥及真实登录业务健康。`ToolboxViewModel.swift` 的 prepareLoginAndProductInParallel/ensureLoginReady 可与游戏准备重叠，但仍等待需要的登录组件就绪。

直接runner的launch_game_once会查询helper `--status`，精确ready才加入DNS兼容层；**不要误写成runner该处无条件启动并等待组件**，正常UI调度和直接runner入口须分别追踪。组件来源/固定策略见 [来源审计](idvLoginSourceAudit.md)。

首装CA授权衔接曾有独立失败记录，不在缺少事件版本对应时硬归因为最近页面不可达。进程/443存在不代表网页/业务可用；不开窗口也不代表后台不可用。

### 2026-10-18调查的既有日志计时

只配对 `starting shared idv-login` 到下一个基础readiness confirmed，重复start覆盖前次未完成起点。32个成功对范围18–152秒、中位36秒；跨版本且排除了失败/未完成，不能当SLA或成功率。

| 原日志钟面日期 | 起止行（当时副本） | 秒 |
| --- | --- | --- |
| 10-07 | 1197→1240 | 35 |
| 10-08 | 1242→1284 | 28 |
| 10-08 | 1286→1329 | 36 |
| 10-09 | 1331→1375 | 33 |
| 10-10 | 1377→1420 | 38 |
| 10-15 | 1422→1465 | 57 |
| 10-16 | 1467→1510 | 40 |
| 10-18 | 1512→1556 | 36 |

只证明当时等待有几十秒成本，不含CA最终完成、游戏可交互/登录实际可用，也非11月4日新测速；未分段不能归咎于Python/Qt或网络某一项。

### 下一步与预启动边界

先定义无账号/无远端副作用的局部健康检查和分层状态，再测启动请求→进程→443归属→CA→管理页→游戏可交互。真实登录需单独验收，不自动执行账号操作。

预启动把等待与用户操作重叠，不能替代功能修复；launchd独立job不自动保证无Dock图标或退出启动器会清理。推荐评估后台代理与按需UI分离、单实例与清理归属。默认关闭只是建议，开关、Dock和生命周期尚未决策，未启用。完整产品约束见[开发计划](developmentPlan.md#plan-prestart可选登录组件预启动)。

## 记录可信度与维护

本页保留可复核的源码入口、样本版本/偏移、定量结果、反证和未知；不把此前报告里不存在的专篇、行号或过强归因直接复制。原始私人日志不进入公开仓；未来复现只保留脱敏工程投影、测试脚本与必要版本/哈希。新证据取得后更新对应问题与STATUS，不建立第三套互相冲突的状态表。