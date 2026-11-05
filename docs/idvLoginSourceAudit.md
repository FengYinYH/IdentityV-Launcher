# IDV Login 来源、更新策略与许可审计

2026-10-05 工程候选审计。运行组件现固定官方 [`v6.3.2-stable`](https://github.com/KKeygen/idv-login/releases/tag/v6.3.2-stable)，精确源码 commit 为 [`3642748dcf82c326ddb5cb657714be9a0885d7fc`](https://github.com/KKeygen/idv-login/tree/3642748dcf82c326ddb5cb657714be9a0885d7fc)。`git ls-remote` 中 `2c93060674be519c94c5d2e7834c2fe55adc72c8` 是 annotated tag object，peeled `^{}` 才是上面的源码 commit；该 tag 未提供可验证的签名。[官方 GitHub Release API](https://api.github.com/repos/KKeygen/idv-login/releases/tags/v6.3.2-stable) 列出 macOS arm64 asset `idv-login-v6.3.2-stable-mac`，198,957,312 bytes，digest `44546da7ec143f73888e8b6e4c4ed53f48d2b03f84c7ca74c20ab8eb310f4045`；从该 URL 取得的资产大小、SHA-256 与 Mach-O 架构均匹配。源码 commit 的 `LICENSE` 哈希仍为 `3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986`。本项目锁定 manifest 和构建期 downloader 与该版本一致。

## 不是单一的“参考”或“复制”关系

| 层 | 实际来源与行为 | 结论 |
| --- | --- | --- |
| 登录服务 | 安装器从官方 Release 直接取得原始 arm64 可执行文件，锁定 198,957,312 bytes 和 SHA-256 `44546da7ec143f73888e8b6e4c4ed53f48d2b03f84c7ca74c20ab8eb310f4045` | 直接使用上游程序，并非本项目重写其登录功能。公开 App 不携带该二进制。 |
| 网易下载核心 | `downloaderCoreComponent.json` 与 bootstrap 从精确上游仓库 commit 获取 Windows 核心，按哈希核验 | 直接取得上游仓库存放的网易二进制；不应称为项目原创下载引擎。其独立再分发权未由 GPL 自动解决。 |
| 下载监督与原生 UI | 本项目 Go `gameDownloader/` 与 Swift UI；Go 的 multipart topic、心跳、pause/resume/finish、状态值等对应上游 `src/download_binary.py` 中公开协议 | 参考并实现同一 IPC 协议，不运行或随包复制该 Python 下载 UI。协议常量相同不等于原样复制整个程序。 |
| 固定版本更新策略 | 本项目 Swift 状态工具生成小型 Python `cloudRes` 委派层，使用上游 `hotfixmgr` 的 import hook 加载原始冻结模块 | 新增兼容适配代码，原始模块继续在官方下载组件内，不把上游整份 Python 源码嵌入本项目。 |

仓库现有历史从“reviewed product baseline”开始，不能由现有 Git 历史证明所有早期编写过程。本次在固定 v6.3.2-stable checkout 上重新运行窄检查：以基线 tracked `.py/.go/.swift/.sh` 文本，和上游 `src/**/*.py` 比较去空行、去首尾空白后的连续完全相同内容；结果为 `localFiles=68 upstreamFiles=96 fiveLineMatches=0`，即 68 个本项目文件与 96 个上游文件间没有连续五行完全相同的块。可运行 `python3 idvLoginComponent/auditSourceOverlap.py <v6.3.2-stable-checkout> --revision 11786f7` 重复该检查。这个结果只排除该限定检查下的直接长段复制，**不能排除翻译、改写、短片段借用，也不是法律上的独立创作证明**。维护者应结合上述直接依赖与协议引用保留来源，不能据此宣称“完全无上游代码关系”。

## 固定组件为何需要外置策略

固定版本的 v6.3.2-stable `src/main.py` 仍无关闭更新检测 CLI/config 参数：启动会调用 `handle_update()`，云端版本与本地版本不同就可能弹更新对话框；云端热更新又可替换模块。因此下载哈希锁只能锁原始资产，不能单独保证运行行为固定。`ignoredVersions` 只跳过已知版本，不能覆盖未来版本；伪造 dev 版本会改变调试/热更新分支，均不采用。上游 `.github/workflows/build-stable.yaml` 将 `github.ref_name` 写入 `buildinfo.VERSION`，所以该 release tag 对应运行时精确版本 `v6.3.2-stable`。

上游 macOS `hotfixmgr.install_import_hook()` 在 `initialize()` 导入 `cloudRes` 前运行，读取 `hotfix_records` 中标为 `overlay_py` 且状态为 `pending_validate` 或 `applied` 的路径。v6.3.2-stable 的 `hotfixmgr.py` 与 v6.3.1-beta 相同，仍未按运行版本过滤这些旧覆盖层；版本升级前必须隔离旧 overlay，不能只替换可执行文件。本项目的受管更新入口先停旧后台并运行迁移：备份配置、将 `hotfix_overlay` 移至版本迁移备份，只删除 `hotfix_probed`、`hotfix_records`、`hotfix_pending_validate`、`hotfix_applied` 和 `hotfix_skipped` 五个热修复字段。其余账号、游戏路径、用户配置和证书资料保留；新版本放入自己的 `6.3.2` 槽，再原子切换 `current`。

组件启动前生成的 Python `cloudRes` 委派层只改版本/热修复入口：让 `get_version()` 返回真实当前版本、`get_hotfixes()` 返回空列表，并替换尚未调用的 `__main__.handle_update` 为“由启动器管理更新”的说明。这样不运行升级比较或 Qt 更新对话框，也屏蔽远程热更新供给；登录所需云端配置仍联网，不能把它描述成组件完全离线。策略接受精确的 v6.3.2-stable 版本表示，拒绝旧版或未知版本及缺失控制点；再次换组件版本时必须复核，旧 helper 合约也须升级。

生成策略由 root-owned 状态工具每次受管启动前写入，路径在组件自己的状态目录，权限 0600。首次转换前的 config 保存在同目录 owner-only `config-before-launcher-update-policy.json`，不进入日志、源码或发行物；其内容可能含账号秘密。新配置只启用项目策略，历史云端 overlay 文件不删除，跨版本迁移备份继续保留。恢复旧行为须停止后台，恢复旧 helper/组件并恢复该私有 config；不能在活动代理中改写。

验证边界：对 v6.3.2-stable 源码确认仍有 `handle_update()` 调用，且 `hotfixmgr.install_import_hook()` 先于 `initialize()`；`hotfixmgr.py` 与上一锁定版一致。更新策略合约测试实际执行从 Swift 源码提取的委派代码，覆盖云端版本不变、远程 hotfix 返回空、上游更新入口被替换，以及 6.3.1-beta/未知版本拒绝。真实 6.3.0→6.3.2 迁移的隔离 fixture 实际调用迁移函数，检查合成账号/配置/证书状态保留、旧 overlay 备份、五个 hotfix 字段清除和同版本重跑无变化；它不调用系统安装器。对官方锁定资产的 CArchive/PYZ 元数据只读检查确认 Python 3.12 标记、`buildinfo.VERSION == v6.3.2-stable`，且 PYZ 目录包含普通模块条目 `cloudRes`、`hotfixmgr`、`main` 与 `buildinfo`。这说明预期冻结模块和外置策略依赖存在且字节码版本标记与策略环境匹配；没有导入或执行任何归档代码，因此不构成真实运行时加载/登录回归。详细元数据证据留在私有外盘检查记录。资产另校验大小、官方 SHA-256 与 arm64 Mach-O 头；GitHub Release tag 没有签名，依赖 HTTPS 官方 API/Release 资产 digest 和精确 hash 锁，不声称做过源签名验证。真实账号、证书链、443/Hosts 和旧安装端到端回归仍未验证。

## Issue #7：system job 首次 CA 授权失败（2026-11-05 审查）

[Issue #7](https://github.com/FengYinYH/IdentityV-Launcher/issues/7) 报告 macOS 26.6.2、M5、RC4/6.3.2 全新状态中，system job 首次调用 `security add-trusted-cert` 因不能进行用户交互被拒，随后 `input()` 对 `/dev/null` 读取 EOF，启动器报 IDVL-START-103。该个例日志与代码吻合，应修复；不能从一个环境推成所有 macOS 26 全新安装必定失败。本机审查环境是 macOS 27.3，未执行真实证书导入或更改信任。

固定源码 `3642748dcf82c326ddb5cb657714be9a0885d7fc` 的 [main.py](https://github.com/KKeygen/idv-login/blob/3642748dcf82c326ddb5cb657714be9a0885d7fc/src/main.py) 与 [certmgr.py](https://github.com/KKeygen/idv-login/blob/3642748dcf82c326ddb5cb657714be9a0885d7fc/src/certmgr.py) 提供以下依据：`generate_certificates_if_needed` 先写 CA 和 mitmproxy 文件，再调用导入；导入失败则调用 input 后退出。`certmgr.import_to_root` 在 macOS 实际启动的是 `sudo security add-trusted-cert` 子进程，不是 Python 直接调用 SecTrust API。现有 job 由 launchd system domain 启动且 StandardInPath=/dev/null。以 AST 提取该生成函数、替换全部证书/导入操作为临时合成实现，已重现首次 EOF、CA/mitm 文件留存，第二次跳过生成且不再次导入。这个实验没有真实密钥、信任设置或网络。第二次 skip 也不证明完整证书材料齐备：上游的服务器证书生成在成功导入之后，合成失败路径中该文件尚不存在，而其缺失检测返回“不算过期”；不能只凭 skip 日志宣称健康。

本项目启动 helper 在 ready 后才调用 `ensure-idv-login-ca`，首次已退出时到不了这一步。`startup_observation` 通过轮询组件子树的 security 进程判断 authorization；短命失败可能漏采，`STARTUP_AUTHORIZATION_SEEN` 仍为 0，最终落入“查看日志或重装固定组件”的通用错误。本机纯字符串运行实际 `isWithdrawnAuthorization` 函数，no-user-interaction 文案返回 false，用户取消文案返回 true；若后续 ensure 路径遇到同样错误，也不能指望现有 75 分支自动兜住。现有 readiness/job fixtures 全部通过，只证明已定义的时序与 plist/锁，不覆盖系统授权 API 在 macOS 26 的行为。

**推荐分期处理**：优先增加可恢复的“首次 CA 授权尚未完成”状态，并在组件明确退出、全新且本轮刚生成的 CA 经现有 PEM/所有权校验、观察到受限的本轮信任失败证据时，允许经用户交互完成信任后最多重试一次。不要仅搜整个旧日志的 error 字符串，不把所有 103 当授权问题，不自动循环重试用户取消。要考虑授权进程完全漏采，判定依赖本轮结果与证书状态，不能只依赖 SEEN 位。长期把证书准备/授权和常驻服务就绪拆为明确阶段，但不建议现在复制上游 CA 生成格式或移动整个代理出 system job；前者耦合密钥/文件版本，后者会扩大端口、身份与生命周期改动。

关键验收仍缺：启动器 → sudo -n helper 的实际 audit/UI 上下文在 macOS 26 和当前系统上能否完成系统授权。sudo 的 -n 只禁止 sudo 自己的交互，不能单凭它证明 security 对话框一定可用或一定不可用。需在获授权的隔离测试环境验证首次允许、拒绝、取消、无交互、已有但不受信任 CA、文件中途变化、服务仍存活、仅第二次才能 ready 等路径，并核对 CA 的精确公钥指纹、信任与代理就绪；不能先删除用户现有证书来制造复现。若当前 helper 上下文不能交互，再设计由前台 UI 承接授权且 root-owned helper 使用已校验公钥快照的路径。本轮仅分析，未删除证书、操作 Keychain/hosts、bootstrap 服务、重装组件或替用户登录。

## 前一锁定版记录：v6.3.1-beta

2026-10-03 的上一锁定版源提交为 [`116149162aecec41c1bfa95bed7a96a7f957da8e`](https://github.com/KKeygen/idv-login/tree/116149162aecec41c1bfa95bed7a96a7f957da8e)，macOS asset 为 197,556,448 bytes，SHA-256 `c789cc56f320052419a4367fcb87971c2dd907e6af37ed8b6b1f8adb17a7bd45`。其版本、源码和资产锁与本次不同；这些值仅作历史审计，不得用于 v6.3.2-stable。

## 公开许可边界

上游文件头授权 GPL-3.0-or-later，锁定 commit 的 `LICENSE` 与已保存许可证文本 hash 一致；本项目同样采用 GPL-3.0-or-later，继续独立保留上游出处与许可材料。公开材料正本见[第三方状态](../notices/THIRD_PARTY_STATUS.md)；本次没有新增上游二进制或 codeload archive 随包分发。上游归档包含网易 DLL/EXE 等未独立审计载荷，不能以 GPL 源码为由自动再分发整包。若以后捆绑/镜像登录组件或下载核心，闭包、对应源码、版权与再分发边界必须重新审核。

### RC5 build 10 的有界恢复候选

仅从本次启动的有界日志区间识别 no-user-interaction 与 CA 导入失败，组件已退出后，在前台 helper 上调用既有公钥快照/所有权/信任校验，再最多 bootstrap 一次。取消或无法交互都返回既有 75 等待态；其他崩溃不重试，旧日志不能触发恢复。恢复判据、取消分类和原状态工具自检通过；没有在测试中导入证书。真实 macOS 授权与全新账号验收仍单列，不能用 fixture 通过代替。

本轮 helper 合约升为 9，UI 会明确要求更新旧合约 8，避免只替换 App 后仍运行旧的 root-owned 启动脚本。组件官方二进制仍固定 6.3.2，同版本 helper 更新保留账号/证书/配置。

## 6.3.3 beta 来源与兼容性（2026-11-05）

所有者要求升级 6.3.3。官方 Release API 当前提供 `v6.3.3-beta`，不存在同版本 stable；源码 tag peeled commit 为 `0cee1f6b5c03b93d999a94bfc6e4baf745456d1b`。已只读下载原始 macOS 资产并核验 199,215,712 bytes、SHA-256 `dcfef8ddd66fae454d30c296dbdc42496a862ed38cd533e0b4b8032b5db9cac5` 与 arm64 Mach-O。GPL 许可正文 SHA-256 仍为 `3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986`；许可生成器源码锁与 Release 标签校验同步更新。

静态读取 CArchive/PYZ（不执行归档代码）确认 Python 3.12、buildinfo.VERSION 为 `v6.3.3-beta`，build commit 与上述来源一致，保留 cloudRes、hotfixmgr、main、buildinfo 模块。源码中 install_import_hook 仍先于 initialize，initialize 导入 cloudRes，handle_update 在后；CloudRes.get_version/get_hotfixes 接口保留。新版本加入云配置签名验证；本项目委派仍加载原始冻结模块，只替换更新/热修复入口，保留签名验证。helper 合约升至 10，旧合约 9 不能被 UI 视为兼容。策略委派 fixture 通过；真实账号登录、首次 CA 授权和升级后的 system job 行为未由此静态核验覆盖，需与 RC5 最终包一并验收。

验证收尾：六个 Go 模块（包含登录下载器真实离线映像 fixture）、受管更新策略（明确拒绝 6.3.2 stable）、helper readiness/首次 CA 恢复/lifecycle、三语 237 keys 与 Swift 模型/进程自检通过。另对合成 6.3.2→6.3.3 状态执行真实迁移函数，验证账号与证书保留、overlay 备份及幂等。官方原始资产通过离线 staging 入口复验；本地最终 App 签名树与 31 个 Mach-O 的 macOS 14 部署目标检查通过。完整构建在旧“拒绝非空目录”自检处失败；按新需求改为允许无关文件、拒绝覆盖已有事务子目录后，仅重编译管理器、重签并续跑全部构建尾段通过。未安装系统 helper、未启动新组件或游戏；未推送、合并、公证或发布。UI 实际排版、文件选择器点击和真实账号升级仍交由 RC5 集成轮验证。
