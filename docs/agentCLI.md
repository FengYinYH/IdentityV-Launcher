# Agent / CLI 契约（schemaVersion 1）

2026-11-05：RC5必须交付的首版运输层框架，GUI 和 Agent 都复用 `IdentityVProductManager`；没有第二套下载或安装实现。旧命令保持兼容。此版本尚无独立 GUI Agent 面板，也没有把所有维护按钮接入 CLI。先运行 `agent help` 获取本包实际支持的命令，不由文档推断未来能力。

## 入口和示例

使用已安装玩家 App 内的管理器，而不是在源码目录寻找不存在的预编译文件。以下路径应以实际 App 为准：

```sh
MANAGER='/Applications/第五人格启动器.app/Contents/Resources/IdentityVProductManager'
"$MANAGER" agent help
"$MANAGER" agent docs
"$MANAGER" agent run status --json
"$MANAGER" agent start install --product mainland --destination-parent '/Volumes/GameDisk/IdentityV'
# 从 accepted 回执取得 taskId；它只表示 worker 已启动，不代表安装完成。
"$MANAGER" agent task '<taskId>'
"$MANAGER" agent events '<taskId>'
"$MANAGER" agent logs '<taskId>' stderr
"$MANAGER" agent cancel '<taskId>'
"$MANAGER" agent run prepare-launch --product global
"$MANAGER" agent run launch --product global
"$MANAGER" agent run stop --product global
"$MANAGER" agent run repair --product mainland
"$MANAGER" agent run inspect --json --product global --path '/Volumes/GameDisk/Client'
"$MANAGER" agent run import --product global --path '/Volumes/GameDisk/Client'
"$MANAGER" agent run remove --product global
```

`run` 前台等待，stdout 是逐行 JSON 事件；`start` 创建后台 worker 并立即输出一行 JSON 回执。两者的任务状态/日志都可随后读取。命令参数直接传入相同核心，无通用只读模式和额外许可开关。已有锁、路径归属、下载完整性、系统权限和运行中保护仍由业务核心执行。`status` 在首次升级时可能触发已有的默认目录迁移，不承诺纯只读。

已支持操作：`status --json`、`check-runtime-prerequisites`、`inspect --json --product mainland|global --path PATH`、`verify-installer --path PATH`、`resolve-download --product …`、`resolve-manifest --json --product …`、`select/install/import/prepare-launch/launch/restart/stop/remove/repair --product …`。安装需要 `--destination-parent`，导入需要 `--path`；明确接受基础清单不符时沿用核心的 `--accept-base-mismatch`。修复/安装可能联网、写入较大文件，启动/停止/删除会影响对应产品；导入的外部文件仍按原有所有权契约保留。`launch` 成功按核心已验证游戏进程/窗口的定义，不等于账号登录成功。

暂未接入：登录组件安装/启停及证书流程、偏好设置、系统/维护工具按钮、诊断采样开关、GUI 自身刷新任务的自动登记、下载任务的远程暂停/恢复控制。取消后重新发相同安装命令沿用核心已有的可续传事务；不保证任意修复步骤可回滚。不要把 cancel 当成 pause，也不要只凭退出码 0 判断 `inspect --json` 基础清单有效：还须读取 `output.valid`。

本版调用文档随App放在 `Contents/Resources/agent-cli.md`，`agent help`给出documentationPath和documentationAvailable，`agent docs`返回JSON中的Markdown text。Agent可在未取得源码仓库时直接读取与当前App匹配的接口文档。以后新增业务功能同步接口和文档，要求见AGENTS；CI流程调整独立于RC5交付。

## 任务、事件和错误

每次新操作生成 UUID。默认持久化到用户支持目录的 `IdentityVOnMac/AgentTasks/<UUID>/`（新任务目录权限 0700）。测试/隔离环境可设置 `IDENTITYV_AGENT_TASK_ROOT`；它只隔离任务记录，**不隔离核心游戏/runtime 数据**，不能用它冒充安全的安装测试 HOME。记录不自动删除；当前没有自动保留期限。

`task.json` 为原子快照：`schemaVersion/taskId/arguments/state/updatedAt`；结束后有 `exitCode/childExitCode/cancellationRequested`，stdout 为不超过 1 MiB 的完整 JSON 时还有 `output`。`updatedAt` 为 Unix 秒。`events.jsonl` 以 `taskId + sequence` 去重；含 `state`、`progress`（原核心 JSON 放在 `payload`）、`cancellation_requested`、`result`。`events` 返回当前历史快照，调用方可轮询并按 sequence 去重；`run` 是实时流，没有另一个持续 follow 连接。未结束的最后一行应等待下次读取再解析。

状态：`queued → awaiting_confirmation（仅删除）/running → succeeded/failed/cancelled`。worker 心跳过 30 秒未更新时，查询额外给出 `observedState: unknown`，不会凭旧 PID 推断成功/失败或结束另一个进程；系统睡眠、等待删除弹窗、worker 崩溃或 SIGKILL 都可能触发，需结合原状态/日志/产品实际状态核查。此版尚无 worker 崩溃后的自动恢复/接管；不要盲目重发变更命令。

前台 run：成功退出 0，操作/协议错误退出 1，已确认信号取消或删除对话框取消退出 130；原核心退出码保存在 childExitCode。start/task/events/logs/cancel 的 0 仅表示本次协议请求成功，终局必须读 task.state。未知命令、缺失任务、错误 UUID 都返回 JSON error 并退出 1。

取消只写请求标记，由 worker 向自己持有的精确核心子进程转发 SIGTERM；不根据历史 PID 发信号。只有信号终止、执行前取消或用户拒绝删除才称 cancelled；若清理后核心返回非零，保留 failed 和 cancellationRequested，避免假称回滚完成。取消与正常完成并发时，以核心真实退出结果为准；不可取消的步骤可能延迟响应。重复 worker 被任务锁拒绝，不会再次执行操作。前台调用方 SIGINT/SIGTERM 同样转为取消请求。强杀 worker 不能保证子任务结束。

## 删除确认

Agent 的 `remove` 在执行核心前显示原生对话框：**「你的 Agent 似乎在删除游戏，确认这样操作吗？」**，默认按钮是取消，并显示具体操作参数。接受后才执行；取消返回 cancelled。没有可用控制台图形会话时返回 `confirmation_unavailable`/failed，不用参数或 stdin 伪造已确认。远程 SSH 但本机存在控制台会话时仍可能需要本机用户操作；目前不支持远程批准。旧 GUI 删除流程保持现有行为；直接调用旧核心 remove 仍是原有接口，没有声称能强制识别所有第三方 Agent。

## 当前日志与历史诊断

`agent logs ID stdout|stderr` 返回结构化 JSON，最多尾部 64 KiB，`truncated` 表示截断。默认隐藏 HOME、URL 查询/用户信息及常见凭据字段；不是任意文本的匿名化保证。原始 stdout.log/stderr.log 留在本地私有任务目录，可供获授权的本机 Agent 深入排错，不自动上传。task 参数/结构化状态包含真实业务路径，调用方应按本地用户数据处理；不要直接贴到公开 issue。

实时任务事件只覆盖此 Agent 任务调用期间，不能替代旧 GUI 或游戏历史日志。现有 `Contents/Resources/IdentityVDiagnosticExporter` 可单独通过 `--preview` 输出采集概要，或 `--output /absolute/new-report.zip` 生成本地历史诊断包（JSON 摘要返回路径，不上传）。它复用现有白名单、有界读取、标识映射和脱敏规则，收集已知启动器/安装历史日志；未知文件不采集，用户 description 原文单独保留。示例：

```sh
'/Applications/第五人格启动器.app/Contents/Resources/IdentityVDiagnosticExporter' --preview
'/Applications/第五人格启动器.app/Contents/Resources/IdentityVDiagnosticExporter' --output /tmp/identityv-report.zip
```

任务日志简单脱敏与公开诊断包规则范围不同，公开分享应优先使用后者并检查内容。此轮没有新增读取任意文件的 API，也没有把游戏账号日志视作 Agent 事件。

## 验证与集成

`productManager/agentSelfTest.command` 用独立 fixture 验证运输层成功、错误/子退出码、后台进度、取消、重复 worker、UUID、日志过滤和失联状态；fixture 没有实际安装行为。`productManager/selfTest.command` 验证真实管理器与原业务回归，完整玩家构建包含新源码。真实安装/修复、控制台删除的确认/取消、无图形会话失败，以及终端退出/睡眠恢复仍须集成机验收；不以 fixture 冒充实机。GUI 当前不自动生成这些 taskId，可在下一步将其调度接入本任务协议。

本轮本地验证：运输层 fixture、真实 ProductManager 自检与隔离 HOME 的 status JSON、三语237键资源、shell语法和工作流 YAML解析均通过。首次默认 sandbox 的编译缓存路径被拒绝后，将缓存放到任务临时目录重跑通过；完整构建首次在 Documents 内继承 File Provider/Finder 元数据导致 codesign 拒绝，改用无扩展属性的独立临时副本验证。没有修改已有 App 签名策略来绕过此问题。

最终验证：无扩展属性的隔离副本完整玩家构建通过，包含六个 Go 模块 test/vet（按原构建覆盖）、管理器/下载核心/诊断导出/权限与来源合约、签名树验证、31枚包内 Mach-O 的14.0目标审计以及 Agent fixture；这不等于下载 runtime 或整个产品已支持 macOS14。已有登录下载器合成映像测试首次遇 hdiutil「资源暂时不可用」，单独重跑通过，随后完整构建通过，未跳过测试。对完成包的真实 ProductManager 再运行隔离 HOME 的 Agent status/JSON输出与 inspect缺参数错误/日志测试通过（`tests/managerAgent.test.py`，也纳入管理器自检入口）。构建保留原 hang-recovery 源码的 actor-isolation warnings，本轮未触碰该并行功能。候选未安装、未公证、未做真实会话删除/全量安装验收；是隔离 dirty-source 开发候选，不作为发行来源凭证。
