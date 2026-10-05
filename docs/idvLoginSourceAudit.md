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

## 前一锁定版记录：v6.3.1-beta

2026-10-03 的上一锁定版源提交为 [`116149162aecec41c1bfa95bed7a96a7f957da8e`](https://github.com/KKeygen/idv-login/tree/116149162aecec41c1bfa95bed7a96a7f957da8e)，macOS asset 为 197,556,448 bytes，SHA-256 `c789cc56f320052419a4367fcb87971c2dd907e6af37ed8b6b1f8adb17a7bd45`。其版本、源码和资产锁与本次不同；这些值仅作历史审计，不得用于 v6.3.2-stable。

## 公开许可边界

上游文件头授权 GPL-3.0-or-later，锁定 commit 的 `LICENSE` 与已保存许可证文本 hash 一致；本项目同样采用 GPL-3.0-or-later，继续独立保留上游出处与许可材料。公开材料正本见[第三方状态](../notices/THIRD_PARTY_STATUS.md)；本次没有新增上游二进制或 codeload archive 随包分发。上游归档包含网易 DLL/EXE 等未独立审计载荷，不能以 GPL 源码为由自动再分发整包。若以后捆绑/镜像登录组件或下载核心，闭包、对应源码、版权与再分发边界必须重新审核。
