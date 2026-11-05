# Agent / CLI 契约（schemaVersion 1）

2026-11-05：RC5必须交付的首版运输层框架，游戏操作复用 `IdentityVProductManager`；启动器更新复用同一Swift更新核心，没有第二套下载或安装实现。旧命令保持兼容。此版本尚无独立 GUI Agent 面板，也没有把所有维护按钮接入 CLI。先运行 `agent help` 获取本包实际支持的命令，不由文档推断未来能力。

## 入口和示例

App 自带短入口 `Contents/Resources/idv`，不另装依赖、不修改 PATH、shell 配置或系统目录。帮助菜单可打开本版文档、复制入口命令。直接复制运行：

```sh
'/Applications/第五人格启动器.app/Contents/Resources/idv' help
'/Applications/第五人格启动器.app/Contents/Resources/idv' run status --json
```

需要频繁调用时，可在当前终端临时定义（不会自动写入 shell 配置）：

```sh
idv() { '/Applications/第五人格启动器.app/Contents/Resources/idv' "$@"; }
idv help
idv start install --product global --destination-parent '/Volumes/GameDisk/IdentityV'
```

`idv` 无参数或 `--help` 返回帮助，其余参数原样转交 `IdentityVProductManager agent`。旧管理器入口继续可用；以下路径以实际 App 为准：

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
"$MANAGER" agent run resolve-location --json --product global --path '/Volumes/GameDisk/Client/dwrg.exe'
"$MANAGER" agent run inspect --json --product global --path '/Volumes/GameDisk/Client'
"$MANAGER" agent run import --product global --path '/Volumes/GameDisk/Client'
"$MANAGER" agent run remove --product global
```

`run` 前台等待，stdout 是逐行 JSON 事件；`start` 创建后台 worker 并立即输出一行 JSON 回执。两者的任务状态/日志都可随后读取。命令参数直接传入相同核心，无通用只读模式和额外许可开关。已有锁、路径归属、下载完整性、系统权限和运行中保护仍由业务核心执行。`status` 在首次升级时可能触发已有的默认目录迁移，不承诺纯只读。

已支持操作：`status --json`、`check-runtime-prerequisites`、`inspect --json --product mainland|global --path PATH`、`resolve-location --json --product mainland|global --path PATH`、`verify-installer --path PATH`、`resolve-download --product …`、`resolve-manifest --json --product …`、`remove-preview --json --product …`、`select/install/import/prepare-launch/launch/restart/stop/remove/repair --product …`。安装需要 `--destination-parent`，导入需要 `--path`；明确接受基础清单不符时沿用核心的 `--accept-base-mismatch`。修复/安装可能联网、写入较大文件，启动/停止/删除会影响对应产品；导入的外部文件仍按原有所有权契约保留。`launch` 成功按核心已验证游戏进程/窗口的定义，不等于账号登录成功。

`resolve-manifest --json --product mainland|global` 返回两服共享的基础清单结构；国服使用对应直下解析器，国际服复用已验证的 GlobalAdapter 和身份转换，不要求国际服存在国服的 directDownload 配置。此命令仅解析元数据，不下载游戏载荷。

`resolve-location` 只读解析已存在的文件或目录：文件使用其父目录，目录使用自身，检测该目录及受支持的客户端子目录。返回 `selectedPath/selectionKind/installDirectory/found/gameRoot?/alreadyRegistered`。`found` 表示发现客户端入口，不表示基础清单或热更新文件已全部校验；需要时继续 `inspect`，再按结果 `import` 或 `install`。没有找到时由调用方决定是否安装，解析命令本身不会写游戏文件。

暂未接入：登录组件安装/启停及证书流程、偏好设置、系统/维护工具按钮、诊断采样开关、GUI 自身刷新任务的自动登记、下载任务的远程暂停/恢复控制。取消后重新发相同安装命令沿用核心已有的可续传事务；不保证任意修复步骤可回滚。不要把 cancel 当成 pause，也不要只凭退出码 0 判断 `inspect --json` 基础清单有效：还须读取 `output.valid`。

本版调用文档随App放在 `Contents/Resources/agent-cli.md`，`agent help`给出documentationPath和documentationAvailable，`agent docs`返回JSON中的Markdown text。Agent可在未取得源码仓库时直接读取与当前App匹配的接口文档。以后新增业务功能同步接口和文档，要求见AGENTS；CI流程调整独立于RC5交付。

## 任务、事件和错误

每次新操作生成 UUID。默认持久化到用户支持目录的 `IdentityVOnMac/AgentTasks/<UUID>/`（新任务目录权限 0700）。测试/隔离环境可设置 `IDENTITYV_AGENT_TASK_ROOT`；它只隔离任务记录，**不隔离核心游戏/runtime 数据**，不能用它冒充安全的安装测试 HOME。记录不自动删除；当前没有自动保留期限。

`task.json` 为原子快照：`schemaVersion/taskId/arguments/state/updatedAt`；结束后有 `exitCode/childExitCode/cancellationRequested`；核心失败同时给出`errorCode: core_operation_failed`与有界脱敏`error`摘要，stdout 为不超过 1 MiB 的完整 JSON 时还有 `output`。`updatedAt` 为 Unix 秒。`events.jsonl` 以 `taskId + sequence` 去重；删除任务在通过预览后还有 `removalPreview`，包含实际目标与确认指纹。事件含 `state`、`progress`（原核心 JSON 放在 `payload`）、`cancellation_requested`、`result`。`events` 返回当前历史快照，调用方可轮询并按 sequence 去重；`run` 是实时流，没有另一个持续 follow 连接。未结束的最后一行应等待下次读取再解析。

状态：`queued → awaiting_confirmation（删除或启动器更新）/running → succeeded/failed/cancelled`。worker 心跳过 30 秒未更新时，查询额外给出 `observedState: unknown`，不会凭旧 PID 推断成功/失败或结束另一个进程；系统睡眠、worker 崩溃或 SIGKILL 都可能触发，需结合原状态/日志/产品实际状态核查。此版尚无 worker 崩溃后的自动恢复/接管；不要盲目重发变更命令。

前台 run：成功退出 0，操作/协议错误退出 1，已确认信号取消或删除对话框取消退出 130；原核心退出码保存在 childExitCode。start/task/events/logs/cancel 的 0 仅表示本次协议请求成功，终局必须读 task.state。未知命令、缺失任务、错误 UUID 都返回 JSON error 并退出 1。

取消只写请求标记，由 worker 向自己持有的精确核心子进程转发 SIGTERM；不根据历史 PID 发信号。只有信号终止、核心明确取消退出130、执行前取消或用户拒绝删除才称 cancelled；核心130必须同时有本任务取消请求。其他非零仍保留 failed 和 cancellationRequested，不凭日志文本判断。取消表示本次操作停止，不保证回滚；安装事务可保留供续传。取消与正常完成并发时，以核心真实退出结果为准；不可取消的步骤可能延迟响应。重复 worker 被任务锁拒绝，不会再次执行操作。前台调用方 SIGINT/SIGTERM 同样转为取消请求。强杀 worker 不能保证子任务结束。

## 删除确认

Agent 的 `remove` 在执行核心前显示原生对话框：**「你的 Agent 要卸载以下位置的游戏，是否继续？」**，默认按钮是取消，使用系统 Icon Services 呈现项目启动器图标，正文只显示一次游戏实际地址，主按钮为「确认卸载」；外部游戏文件明确标为保留。卸载复用 GUI 的同一清除行为，不增加第二套删除实现。`remove-preview --json --product …`复用核心只读预检，返回`gamePath/externalGameRoot/targets/removalToken`；无法取得有效目标时直接失败。确认后核心在修改锁内、停止游戏前验证指纹，地址或所有权变化则拒绝并要求重新确认；不以旧确认删除新的绑定。内部确认参数不能由 Agent 调用者指定。接受后才执行；取消返回 cancelled。等待确认时维持心跳，`agent cancel ID`或前台SIGINT/SIGTERM会关闭本任务确认框并返回cancelled，不需再由人点击取消。接受任务后即有可读的空stdout/stderr流，不以缺文件报错。没有可用控制台图形会话时返回 `confirmation_unavailable`/failed，不用参数或 stdin 伪造已确认。远程 SSH 但本机存在控制台会话时仍可能需要本机用户操作；目前不支持远程批准。旧 GUI 删除流程保持现有行为；直接调用旧核心 remove 仍是原有接口，没有声称能强制识别所有第三方 Agent。

## 当前日志与历史诊断

`agent logs ID stdout|stderr` 返回结构化 JSON，最多尾部 64 KiB，`truncated` 表示截断。默认隐藏 HOME、URL 查询/用户信息及常见凭据字段；不是任意文本的匿名化保证。原始 stdout.log/stderr.log 留在本地私有任务目录，可供获授权的本机 Agent 深入排错，不自动上传。task 参数/结构化状态包含真实业务路径，调用方应按本地用户数据处理；不要直接贴到公开 issue。

实时任务事件只覆盖此 Agent 任务调用期间，不能替代旧 GUI 或游戏历史日志。现有 `Contents/Resources/IdentityVDiagnosticExporter` 可单独通过 `--preview` 输出采集概要，或 `--output /absolute/new-report.zip` 生成本地历史诊断包（JSON 摘要返回路径，不上传）。它复用现有白名单、有界读取、标识映射和脱敏规则，收集已知启动器/安装历史日志；未知文件不采集，用户 description 原文单独保留。示例：

```sh
'/Applications/第五人格启动器.app/Contents/Resources/IdentityVDiagnosticExporter' --preview
'/Applications/第五人格启动器.app/Contents/Resources/IdentityVDiagnosticExporter' --output /tmp/identityv-report.zip
```

任务日志简单脱敏与公开诊断包规则范围不同，公开分享应优先使用后者并检查内容。此轮没有新增读取任意文件的 API，也没有把游戏账号日志视作 Agent 事件。

## 验证与集成

`productManager/agentSelfTest.command` 用无游戏副作用的 fixture 验证回执、成功/失败、原子状态、子退出码、后台进度、信号与协作取消、未请求退出130仍失败、重复 worker、UUID、日志过滤和失联状态；有控制台时也验证原生确认框的心跳及API/SIGTERM取消，无控制台时验证拒绝执行。`productManager/selfTest.command` 编译真实管理器并在隔离HOME运行状态/错误、随包短入口和位置API，核心自检覆盖选择文件/目录、重复登记保留所有权、删除预览与指纹。完整玩家构建包含这些入口和文档。

整合审查复现并修复了确认框等待期间无法响应取消、回执后日志文件尚未创建，以及任务失败缺少可读摘要的问题。共享核心的主动中断现在使用明确的130退出码，不靠诊断文字推断。位置选择和删除目标预览均复用业务核心，未创建另一套文件检测/删除实现。

真实隔离安装已观察到国际服报告约14.6MB下载进度，取消后子下载进程收束并保留未完成事务；这不是全量安装验收。最终整合包仍须单独记录构建、日用更新、选择器/三语言布局及原生删除确认点击的实际结果。命令行进程在Computer Use中可能无法绑定；API取消验证不能替代已点击“确认卸载”的实测。既有国际服完整安装/公告场景记录按对应构建保存，不冒充新接口全量重装。

最终界面回归补充：原生Icon Services冷加载曾使awaiting_confirmation早于实际模态循环，完整构建中的心跳回归捕获此问题。现在完成预检/图标准备后才发布等待确认，并在进入模态前再次检查取消；心跳测试允许有限调度延迟，仍要求实际时间戳前进。隔离SwiftUI副本已实测文件/目录选择、取消、安装确认后取消及三语言布局，未操作玩家游戏。

已确认的锁定核心空间失败会在事件payload中提供 `event: failure`、`errorCode: download_disk_space_required`、`coreState: 206`和`requiredBytes`；任务终局仍为failed，通用任务errorCode继续兼容。未知206不套用此解释。机器键和值不随界面语言变化。

## 启动器本身的更新

```sh
idv run launcher-update-check
idv start launcher-update-install
idv task '<taskId>'
idv events '<taskId>'
idv cancel '<taskId>'
```

这两项不带product或路径参数。check读取公开GitHub Releases，返回output.available/currentVersion及可用版本/pageURL；不下载安装包。install重新检查，发现新版时显示与产品一致的原生“已检测到新版本，是否更新？”确认，不能由参数假定已同意；无控制台会话返回confirmation_unavailable。有更新且确认后才校验大小/SHA、项目Developer ID/Gatekeeper、系统/架构，并同址替换与重启；没有新版则成功返回available=false。

两项使用真实App的显式 `--launcher-agent-operation` 后端，GUI用相同checker/preparer/helper，不复制第二套更新器。Resources/idv保持独立，普通GUI参数及`--launcher-update-receipt`始终进入GUI。检查缓存限于该后端进程，跨任务调用方应遵守GitHub限流；不后台轮询。

事件phase包括checking/downloading/applying；确认时task.state=awaiting_confirmation。下载准备阶段API取消可终止本任务；提交交给助手后cancellable=false，晚到的取消记录cancellation_too_late并等待真实结果，不强杀替换事务。用户在确认框点取消也返回cancelled。成功仅在新GUI回执匹配且旧备份/本次临时包清理完成后产生；helper启动或ready不是成功。助手结果将物理目标与启动协议分开：`targetState=original|replacement|unknown`，`targetReplaced=false|true|null`；false仅在旧目标已验证（包括已验证回退）时返回，null表示无法确认。`startupConfirmed`表示新版启动回执已确认，旧`installed`仅为它的兼容别名，false绝不证明磁盘仍是旧版。`recoveryRequired`表示需要恢复或收尾；此时返回`targetPath/transactionPath`，仅在备份实际存在时返回`backupPath`。`cleanupComplete`和error仍须读取。活新版无回执时targetReplaced=true、startupConfirmed=false、recoveryRequired=true；回退失败则targetReplaced=null，不从failed或installed=false反推原目标未变。

更新助手独占活admission及现有产品修改锁，admission按实际用户临时区与App canonical路径分组，不随业务HOME变化；普通worker和直接管理器入口持共享lease，覆盖只读扫描及下载/安装整个时段；更新install运输层自身除外，以免等待自身锁。新业务会快速返回busy，不使用旧PID或task.json猜测活动。只读位置解析不修改游戏与安装记录，但可创建内部锁文件。更新需要退出游戏、等待组件/产品事务完成；不强停游戏、不触碰游戏/runtime/账号。CLI在用户确认后可正常请求同址旧GUI退出，并等待新GUI回执。

验证：真实运输层+mock后端覆盖上述UUID、lease、确认/早晚取消及完成语义；原生确认点击和真实签名替换仍待实测。KVM暂停时可运行`productManager/agentSelfTest.command --headless`（完整构建用`IDENTITYV_TEST_HEADLESS=1`），只推迟原生确认UI测试段并明确标记，不影响生产确认。
