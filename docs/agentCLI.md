# Agent / CLI 契约（schemaVersion 1）

适用于包含本文档的启动器版本。先运行 `agent help` 获取本包实际支持的命令。

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

本版调用文档随App放在 `Contents/Resources/agent-cli.md`，`agent help`给出documentationPath和documentationAvailable，`agent docs`返回JSON中的Markdown text。Agent可在未取得源码仓库时直接读取与当前App匹配的接口文档。

## 任务、事件和错误

每次新操作生成 UUID。默认持久化到用户支持目录的 `IdentityVOnMac/AgentTasks/<UUID>/`（新任务目录权限 0700）。测试/隔离环境可设置 `IDENTITYV_AGENT_TASK_ROOT`；它只隔离任务记录，**不隔离核心游戏/runtime 数据**，不能用它冒充安全的安装测试 HOME。记录不自动删除；当前没有自动保留期限。

`task.json` 为原子快照：`schemaVersion/taskId/arguments/state/updatedAt`；结束后有 `exitCode/childExitCode/cancellationRequested`；核心失败同时给出`errorCode: core_operation_failed`与有界脱敏`error`摘要，stdout 为不超过 1 MiB 的完整 JSON 时还有 `output`。`updatedAt` 为 Unix 秒。`events.jsonl` 以 `taskId + sequence` 去重；删除任务在通过预览后还有 `removalPreview`，包含实际目标与确认指纹。事件含 `state`、`progress`（原核心 JSON 放在 `payload`）、`cancellation_requested`、`result`。下载核心进度在可用时包含 `payload.coreState`，其中 `6` 和 `7` 为核心报告的暂停状态；状态变化会单独发出，即使字节数未变化。`events` 返回当前历史快照，调用方可轮询并按 sequence 去重；`run` 是实时流，没有另一个持续 follow 连接。未结束的最后一行应等待下次读取再解析。

状态：`queued → awaiting_confirmation（删除或启动器更新）/running → succeeded/failed/cancelled`。worker 心跳过 30 秒未更新时，查询额外给出 `observedState: unknown`，不会凭旧 PID 推断成功/失败或结束另一个进程；系统睡眠、worker 崩溃或 SIGKILL 都可能触发，需结合原状态/日志/产品实际状态核查。不要盲目重发变更命令。

前台 run：成功退出 0，操作/协议错误退出 1，已确认信号取消或删除对话框取消退出 130；原核心退出码保存在 childExitCode。start/task/events/logs/cancel 的 0 仅表示本次协议请求成功，终局必须读 task.state。未知命令、缺失任务、错误 UUID 都返回 JSON error 并退出 1。

取消只写请求标记，由 worker 向自己持有的精确核心子进程转发 SIGTERM；不根据历史 PID 发信号。只有信号终止、核心明确取消退出130、执行前取消或用户拒绝删除才称 cancelled；核心130必须同时有本任务取消请求。其他非零仍保留 failed 和 cancellationRequested，不凭日志文本判断。取消表示本次操作停止，不保证回滚；安装事务可保留供续传。取消与正常完成并发时，以核心真实退出结果为准；不可取消的步骤可能延迟响应。重复 worker 被任务锁拒绝，不会再次执行操作。前台调用方 SIGINT/SIGTERM 同样转为取消请求。强杀 worker 不能保证子任务结束。

已确认的空间不足事件可包含 `errorCode: download_disk_space_required`、`coreState: 206` 和 `requiredBytes`；任务仍以 failed 结束。

## 删除确认

Agent 的 `remove` 在执行核心前显示原生对话框：**「你的 Agent 要卸载以下位置的游戏，是否继续？」**，默认按钮是取消，使用系统 Icon Services 呈现项目启动器图标，正文只显示一次游戏实际地址，主按钮为「确认卸载」；外部游戏文件明确标为保留。卸载复用 GUI 的同一清除行为，不增加第二套删除实现。`remove-preview --json --product …`复用核心只读预检，返回`gamePath/externalGameRoot/targets/removalToken`；无法取得有效目标时直接失败。确认后核心在修改锁内、停止游戏前验证指纹，地址或所有权变化则拒绝并要求重新确认；不以旧确认删除新的绑定。内部确认参数不能由 Agent 调用者指定。接受后才执行；取消返回 cancelled。等待确认时维持心跳，`agent cancel ID`或前台SIGINT/SIGTERM会关闭本任务确认框并返回cancelled，不需再由人点击取消。接受任务后即有可读的空stdout/stderr流，不以缺文件报错。没有可用控制台图形会话时返回 `confirmation_unavailable`/failed，不用参数或 stdin 伪造已确认。远程 SSH 但本机存在控制台会话时仍可能需要本机用户操作；

## 当前日志与历史诊断

`agent logs ID stdout|stderr` 返回结构化 JSON，最多尾部 64 KiB，`truncated` 表示截断。默认隐藏 HOME、URL 查询/用户信息及常见凭据字段；不是任意文本的匿名化保证。原始 stdout.log/stderr.log 留在本地私有任务目录，可供获授权的本机 Agent 深入排错，不自动上传。task 参数/结构化状态包含真实业务路径，调用方应按本地用户数据处理；不要直接贴到公开 issue。

实时任务事件只覆盖此 Agent 任务调用期间，不能替代旧 GUI 或游戏历史日志。现有 `Contents/Resources/IdentityVDiagnosticExporter` 可单独通过 `--preview` 输出采集概要，或 `--output /absolute/new-report.zip` 生成本地历史诊断包（JSON 摘要返回路径，不上传）。它复用现有白名单、有界读取、标识映射和脱敏规则，收集已知启动器/安装历史日志；未知文件不采集，用户 description 原文单独保留。示例：

```sh
'/Applications/第五人格启动器.app/Contents/Resources/IdentityVDiagnosticExporter' --preview
'/Applications/第五人格启动器.app/Contents/Resources/IdentityVDiagnosticExporter' --output /tmp/identityv-report.zip
```

任务日志简单脱敏与公开诊断包规则范围不同，公开分享应优先使用后者并检查内容。

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

## 打开 IDV Login 管理后台

```sh
idv run login-admin-open
```

此命令不接受额外参数，使用与界面「打开后台」相同的就绪检查和系统浏览器入口。组件的受管本机 443 监听及 hosts 检查通过后，打开 `https://localhost/_idv-login/index`；不自动安装或启动组件，不读取账号配置，不附加凭据，不改变代理或证书。成功输出 `output.opened=true`，仅表示系统接受打开请求，不表示网页已经载入或账号可登录。未运行、初始化、配置异常、旧 helper 无法验证或浏览器拒绝均失败；后端 stderr 错误为 `login_admin_unavailable`，任务层仍使用 `core_operation_failed`，同时读取错误摘要。对不同版本先查询 `idv help`。

## 界面语言

`idv run language-get` 返回 `output.language`；`idv run language-set en` 设置语言。可选值为 `system`、`zh-Hans`、`zh-Hant`、`en`；其他值失败且不修改设置。设置使用与界面菜单相同的用户偏好，游戏语言和服务器不受影响。

## 登录组件跟随游戏启动

`idv run login-follow-get` 返回 `output.enabled`；`idv run login-follow-set on` 或 `off` 修改偏好。启用要求已安装组件；此操作不启动组件，也不代替首次证书提示和系统授权。

## 停止 IDV Login

`idv run login-stop` 请求停止组件并等待停止脚本结束。开始交接前可取消；进入 `running` 且 `cancellable=false` 后，取消只记录请求，不中断特权操作，须等待终态。脚本成功返回时 `output.stopped=true`；失败为 `failed`，没有收到可靠结果或等待超时为 `unknown`，应核对实际组件状态。系统可能要求管理员授权。

## 启动 IDV Login

`idv run login-start` 检查组件和辅助程序，再等待启动及本机代理就绪。首次启动需要在本机确认系统授权提示，并按 macOS 提示完成授权；无控制台会话时返回 `confirmation_unavailable`。若系统授权未完成，返回 `login_authorization_required`，再次执行命令可重新确认。`output.ready=true` 表示受管代理已就绪；交接后取消、超时和未知结果的处理与 `login-stop` 相同。

## 反馈邮件草稿

`idv run feedback-draft '标题' '正文'` 将无附件的反馈内容交给系统邮件服务；标题或正文至少一项非空。`output.requested=true` 仅表示已向系统邮件服务发出请求；请检查邮件客户端是否打开草稿，再由用户自行发送。需要本机图形会话和可用邮件客户端；交接后取消只记录请求，异常退出或超时结果为 `unknown`。参数会写入本地私有任务记录，避免直接公开分享。诊断包可用上面的导出器单独生成。

## 暂停和恢复安装下载

对 `idv start install ...` 返回的任务执行 `idv pause '<taskId>'` 或 `idv resume '<taskId>'`。命令仅控制仍在运行的该 Agent 安装任务；须已进入下载核心阶段。返回 `status: observed` 表示收到目标核心状态，暂停为 `6` 或 `7`，恢复为 `1` 至 `5`；核心协议不提供带请求编号的确认。超时、任务结束或阶段变化返回 `unknown`，应检查任务事件和实际状态。任务被取消或进程失联时不可依据控制文件推断下载状态。 build22独立国际服真实任务已观察核心状态2→3→6→2→3，pause/resume均返回observed，随后取消终态130；这是单次实测，协议仍无请求编号，不代表所有网络或竞态条件均通过。

## 安装或更新 IDV Login

`idv start login-install` 返回任务编号；用 `idv task '<taskId>'`、`idv events '<taskId>'` 查询下载进度和终态；下载器退出后任务快照包含 `downloadExitCode` 和 `downloadTerminationReason`。组件已是当前或更新版本且辅助程序可用时，`output.alreadyInstalled=true`。否则启动器下载并校验组件，在本机显示管理员授权提示；下载及确认阶段可用 `idv cancel '<taskId>'` 取消；离线载荷阶段会等待下载器退出并尝试卸载映像；取消后长时间未收到退出结果时返回 `unknown`。确认后进入 `cancellable=false` 的特权交接，取消只记录请求，必须等待最终结果。成功时 `output.installed=true`；交接异常退出或超时为 `unknown`，应检查实际组件状态后再决定是否重试。安装器保留既有运行中游戏保护，并可能要求 macOS 管理员授权。
