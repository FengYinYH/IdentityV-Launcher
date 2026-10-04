# 国服与国际服修复共用网易下载核心

本文记录启动器将国服、国际服首装与完整性修复接入同一下载链的依据与适用范围。结论基于上游 `KKeygen/idv-login` 的 `main` 提交 `6e5523e7933c0c28662b1af2a77e129b512423b6`；上游代码可从其公开仓库按该 SHA 复核。本仓 `downloaderCoreComponent.json` 锁定的核心来自提交 `9b1ff598da6cb9ae6a952a8978ccf88bc8b2ae5c`，其中 `downloadIPC.exe` 为 34,378,168 字节、SHA-256 `5c11d3188d271c1df88d36d98bb440437d29e8a41c88dfd38602ce3c60c56f82`。该摘要与本轮 main checkout 的 `binaries/downloadIPC.exe` 完全一致，因而本仓实际锁定的核心就是已审查 main 所带的二进制。对二进制只做了静态字符串检查，可见 `oversea`、`isOverSea`、`LoadingBayAppPath`、`getLoadingBayHost`、`GlobalIsOversea` 与 `overseaUpdateServerURL` 等海外路由相关标记；没有运行它。

## 已证实的协议

上游 [`src/gamemgr.py`](https://github.com/KKeygen/idv-login/blob/6e5523e7933c0c28662b1af2a77e129b512423b6/src/gamemgr.py) 按分发来源区分国服和海外 LoadingBay 元数据接口。海外游戏清单仍提供分发 ID、`app_content_id`、版本号、文件路径、大小、XXH64 和操作类型；上游同时把 `oversea` 布尔值写入下载任务。[`src/main.py`](https://github.com/KKeygen/idv-login/blob/6e5523e7933c0c28662b1af2a77e129b512423b6/src/main.py) 的 `handle_download_task` 在内容 ID、分发 ID 和下载目录有效时调用 `downloadIPC.exe`，将 `--gameid`、`--contentid`、`--targetVersion`、`--repairListPath` 与 `--oversea:1` 一起传入。相同的 ZeroMQ 控制/进度协议定义在 [`src/download_binary.py`](https://github.com/KKeygen/idv-login/blob/6e5523e7933c0c28662b1af2a77e129b512423b6/src/download_binary.py)，不会因海外路由切换。

`ext/v6.3.1-beta-CHANGELOG` 记载该版本支持国际服下载、更新和修复。README 仍另列官方国际服安装器下载链接；它不代表完整性修复必须使用安装器。

这些源码共同证明该上游版本确实将国际服下载接入同一个 `downloadIPC.exe` 命令接口，并显式选择海外服务。它们没有证明网易核心二进制的内部实现，也没有证明所有未来版本、所有分发类型或每一份清单均兼容。

## 本仓实现

国际服 adapter 继续负责从 `api.loadingbay.com` 获取并校验国际服清单，包括固定产品身份、版本、文件路径、大小、MD5、XXH64、CDN 地址和操作类型。首装和修复都把经过 adapter 校验的身份及 planner 所需字段转换为共同 manifest：国际服 app ID 40 作为分发 ID，`h55naxx2gb` 作为游戏 ID，`app_content_id` 作为内容 ID，文件 XXH64 用于计划和下载后的完整性验证。

共同 planner 继续拒绝不安全路径、重复文件、不支持的操作、身份不匹配或无效校验值。共同 supervisor 在任务中显式设置 `oversea=true`，最终给 `downloadIPC.exe` 传 `--oversea:1`。国际服专用 prefix、游戏路径映射、运行中进程检查、Wine 生命周期和发布恢复标记仍由产品管理器控制，下载核心只获得该 prefix 与游戏目录需要的路径。此前 `globalAdapter/download.go` 的独立直连游戏文件下载及其 supervisor 已移除，避免继续维护第二套内容传输协议；`IdentityVGlobalAdapter` 保留为国际服清单与安装器地址解析器。

两服游戏内容首装与修复的传输、清单扫描和下载后复验已共用。各自的安装事务、恢复证据、prefix 和最终游戏链接仍分开，因为它们绑定的是不同产品路径。这个抽取复用了现有 task `oversea` 字段、Wine prefix 准备逻辑、manifest planner 和 supervisor，不改变发布状态机。

## 结论状态与边界

- **已证实**：指定上游提交把国际服元数据、内容 ID、分发 ID 和海外标志交给同一下载核心命令接口；本仓任务结构及 supervisor 已支持 `oversea` 参数。
- **已证实**：本次实现把两服首装及修复纳入共享 planner、下载核心和下载后复验，并保留国际服产品身份、隔离 prefix 与独立发布状态机。
- **已推翻**：本仓此前注释把国际服下载核心协议表述为不能与国服共用。该结论与上述上游源码不符；源码证据支持首装和修复都使用下载核心，因此本次移除了重复的 global 直连文件下载器，同时保留仍承担产品解析职责的 adapter。
- **仍未知**：当前网易二进制对国际服所有更新操作、实时服务可用性、特定网络环境与 Wine 版本的实际兼容性。源码级协议证据和 Go/Swift 合约测试不替代真实国际服下载、更新或修复回归。

切换带来的主要失败路径变化是：国际服文件下载不再由本仓 `globalAdapter` 逐文件暂存后原子替换，而改由网易 core 按 repair list 执行，与国服采用相同的写入和续传机制。修复前 planner 根据 XXH64 扫描并生成 repair list；核心非零退出或被取消时，产品管理器不更新已安装版本记录，并收束该 prefix 的 Wine server。重试会重新扫描当前游戏树并生成新 repair list，因此缺失或摘要不符的文件仍能被发现并再次交给核心；核心返回成功后还必须通过整树 planner 复验才更新记录。首次安装的失败会留下 `downloading` 事务标记和隔离 staging 目录，正式目录链接及安装记录不会发布；同版本重试重新生成完整 repair list 并复用 staging，若清单版本变化则拒绝混合续传。没有证据表明核心在单个文件中断时原子写入或保留旧文件，因此修复期间目标文件可能暂时不完整，但下次 planner 会检测并重试；launcher 的 prefix/运行进程检查和操作锁避免对活动客户端执行修复。

本轮 `go test ./...` 已分别通过 `manifestPlanner/`、`gameDownloader/` 与 `globalAdapter/`；`productManager/selfTest.command` 通过，覆盖身份转换、海外任务参数和产品特定热更新判断。真实游戏文件和运行进程不属于这些合约测试的证明范围；国际服核心的单文件写入/中断行为及真实网络下首装续传仍需实机验证。
