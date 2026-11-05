# 项目状态

更新：2026-11-05。本页是当前状态正本；历史、取舍与验证证据见专题，规划见[开发计划](docs/developmentPlan.md)。

## 当前版本与验收

- 公开版：`1.0.0-rc.4`（2026-11-04）；上一版 RC3（2026-10-09）。
- 本机候选与日用 App：`1.0.0-rc.5` / build 13，干净源码 `51760a9`。完整构建、全部自检、签名树与 31 个包内 Mach-O 的 macOS14 部署目标审计通过；本地测试 DMG 和对应材料 ZIP 已生成、挂载复验与哈希复算通过，未公证。
- 日用更新保留旧版备份，安装及 Terra UI 烟测后原产品/runtime 绑定哈希不变。新包实际通过仅国际服预检、启动与公告场景；按所有者确认，公告页即本轮国际服验收终点，不要求账号登录/大厅。测试国际服已正常退出，国服和 IDV Login 保留。
- 原 17,602,266,736 bytes 隔离全量安装、暂停恢复、取消后续传、最终复验在前序候选完成；build13 干净 VM 冷测仍是独立验收，不把旧包结果冒充最终新包首装。

## 当前问题与边界

| 项目 | 当前状态 | 入口 |
| --- | --- | --- |
| Wine/GnuTLS 路径（#4、PR #5） | 已采用 PR5 窄路径恢复并保留诊断，全量安装通过 | [下载专题](docs/downloadCoreUnification.md) |
| 304 | 精确锁定核心已定位为清单重试耗尽，现立即失败；真实464字节帧回放及2→304→重复10回归通过，日志只保留长度/hash；不外推所有TLS根因 | [锁定定义与证据](docs/downloadCoreUnification.md#build-13：304-锁定定义与按实际产品-runtime-确认2026-11-05) |
| 299 与两服绑定 | 启动前按产品固定实际runtime，验证失败不借另一服；仅国际服实机通过，A/B不同与缺失绑定回归通过，但未制造真实A/B双游戏场景 | [下载专题](docs/downloadCoreUnification.md) |
| 默认/自定义路径与导入 | 默认目录从不存在开始安装通过；允许无关兄弟文件，保留事务目录保护；文件级导入、三语同行按钮、检测与取消通过。错误文件拒绝行为通过，短提示未捕获；未安装状态的选择取消待VM | [开发者指南](docs/developerGuide.md#自定义安装与已有目录检测rc5-build-10-候选) |
| 完整性与修复 | 官方基础清单检测/单文件损坏检测通过；不声称证明全部热更新完整性，外部导入不自动修复或删除原文件 | [下载专题](docs/downloadCoreUnification.md) |
| IDV Login / #7 | 源码固定官方6.3.3 beta、helper契约10；来源/迁移/CA有界恢复回归通过。现机仍为6.3.2与helper8，新系统首次CA及633真实运行待验 | [来源审计](docs/idvLoginSourceAudit.md) |
| macOS14 | 最低目标明确为14；当前整个runtime的82个Mach-O中，DXMT winemetal.so唯一要求15。已修复审计符号链接零文件假通过；不能宣称完整支持14 | [DXMT审计与测试矩阵](runtimeManifest/dxmt080MacOS14Compatibility.md) |
| 鼠标捕获丢失 | 单次事件未复现，缺少完整时序证据，不猜测修改Wine | [窗口与登录调查](docs/windowAndLoginInvestigation.md) |
| 登录面板比例、游戏越屏、卡顿/语音气泡音 | 原有问题保留，与本次下载/路径修复分开 | [已知问题](docs/knownIssues.md) |

## 协作与下一步

- PR #5/#6 原作者历史保留已在纯临时分支评估：两个原 PR 可干净合并，再调和RC5有四处冲突及旧测试接口问题；最终树可保持与已验51760a9完全相同并保留三个原始祖先。临时评估头d7ec823，不合入当前分支；GitHub核查时两PR仍open、未merged。正式方案由所有者决定，采用新历史后须重建来源身份和包，见[评估与替代方案](docs/downloadCoreUnification.md#pr-5/6-作者历史保留评估2026-11-05，仅隔离实验)。
- macOS14需隔离准备LLVM15/mingw与匹配Wine ABI输入，重建DXMT Metal3.1分支，再做14 VM安装/下载和真实14 GPU验收；详细矩阵已记录，不改二进制版本号伪兼容。
- 干净VM的最终包首装/续传/校验/游戏进程及新组件授权验收接续；VM黑屏按所有者授权的Metal限制单列。
- 反馈讨论组补丁仍因先前自动审批拒绝保持未应用，没有重试或绕过。主仓所有者未提交README修改未被覆盖。
- 没有推送、合入共享分支、发布、公证或对外回复。

## 后续方向与接手

窗口/跨平台UI、登录健康、可选预启动、Metal FX及游戏多开仍按[开发计划](docs/developmentPlan.md)原有边界推进。先读[AGENTS](AGENTS.md)，核对工作树和并行状态，再从[开发者指南](docs/developerGuide.md)、[地图](projectMap.md)与专题续接；不要用reset/clean清理他人的工作。

## 隔离 Agent / CI 候选（2026-11-05）

独立分支增加 ProductManager agent 运输层（任务UUID/后台运行/状态和进度/取消/有界脱敏日志/原生删除确认），原GUI核心不复制；fixture合约通过。没有新增通用只读或确认限制。现存历史日志通过原诊断导出器读取/导出，任务实时事件和历史诊断不混淆。具体支持矩阵与未验收项见[Agent契约](docs/agentCLI.md)。未改日用 App/RC5并行树；本轮是明确隔离候选，待安全调和后做真实会话验收。

GitHub只读API确认公开main仓库目前workflows/runs/self-hosted runners均为0；新增本地checks工作流未推送或远端执行。[CI调查](docs/ciWorkflow.md)记录官方资源/系统退役/网络/费用限制，并建议合约CI+本地真实Mac的混合流程，release保持独立验收。

Agent候选最终检查：完整玩家构建及包内签名/31枚Mach-O审计通过，完成包的真实CLI status与错误/日志在隔离HOME通过；Agent fixture已加入完整构建，真实manager协议测试加入模块selfTest入口。已有idv-login合成映像测试曾短暂资源不足，单独及随后完整重跑均通过；未跳过。没有日用安装/公证/真实删除确认或全量安装验收，后两项仍是集成门。
