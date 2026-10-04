# IDV Login 来源、更新策略与许可审计

2026-10-04 工程候选；未公开发布。审计基线为本项目 `11786f7`，上游最新 main 实际拉取为 [`6e5523e7933c0c28662b1af2a77e129b512423b6`](https://github.com/KKeygen/idv-login/tree/6e5523e7933c0c28662b1af2a77e129b512423b6)。运行组件仍固定官方 [`v6.3.1-beta`](https://github.com/KKeygen/idv-login/releases/tag/v6.3.1-beta)，源提交 [`116149162aecec41c1bfa95bed7a96a7f957da8e`](https://github.com/KKeygen/idv-login/tree/116149162aecec41c1bfa95bed7a96a7f957da8e)；研究 main 不自动升级组件。

## 不是单一的“参考”或“复制”关系

| 层 | 实际来源与行为 | 结论 |
| --- | --- | --- |
| 登录服务 | 安装器从官方 Release 直接取得原始 arm64 可执行文件，锁定 197,556,448 bytes 和 SHA-256 `c789cc56f320052419a4367fcb87971c2dd907e6af37ed8b6b1f8adb17a7bd45` | 直接使用上游程序，并非本项目重写其登录功能。公开 App 不携带该二进制。 |
| 网易下载核心 | `downloaderCoreComponent.json` 与 bootstrap 从精确上游仓库 commit 获取 Windows 核心，按哈希核验 | 直接取得上游仓库存放的网易二进制；不应称为项目原创下载引擎。其独立再分发权未由 GPL 自动解决。 |
| 下载监督与原生 UI | 本项目 Go `gameDownloader/` 与 Swift UI；Go 的 multipart topic、心跳、pause/resume/finish、状态值等对应上游 `src/download_binary.py` 中公开协议 | 参考并实现同一 IPC 协议，不运行或随包复制该 Python 下载 UI。协议常量相同不等于原样复制整个程序。 |
| 固定版本更新策略 | 本项目 Swift 状态工具生成小型 Python `cloudRes` 委派层，使用上游 `hotfixmgr` 的 import hook 加载原始冻结模块 | 新增兼容适配代码，原始模块继续在官方下载组件内，不把上游整份 Python 源码嵌入本项目。 |

仓库现有历史从“reviewed product baseline”开始，不能由现有 Git 历史证明所有早期编写过程。本次可重复的窄检查：以基线 tracked `.py/.go/.swift/.sh` 文本，和所读 main 的 `src/**/*.py` 比较去空行、去首尾空白后的连续完全相同内容；68 个本项目文件与 91 个上游文件间，没有连续五行完全相同的块。可运行 `python3 idvLoginComponent/auditSourceOverlap.py <upstream-checkout> --revision 11786f7` 重复该检查。这个结果只排除该限定检查下的直接长段复制，**不能排除翻译、改写、短片段借用，也不是法律上的独立创作证明**。维护者应结合上述直接依赖与协议引用保留来源，不能据此宣称“完全无上游代码关系”。

## 固定组件为何需要外置策略

固定版本的 `src/main.py` 无关闭更新检测 CLI/config 参数：启动调用 `handle_update()`，云端版本与本地版本不同就可弹更新对话框；云端热更新又可替换模块。因此下载哈希锁只能锁原始资产，不能单独保证运行行为固定。`ignoredVersions` 只跳过已知版本，不能覆盖未来版本；伪造 dev 版本会改变调试/热更新分支，均不采用。

上游的 macOS `hotfixmgr.install_import_hook()` 在 `initialize()` 导入 `cloudRes` 前运行，读取 `hotfix_records` 的 `overlay_py/applied` 记录。本项目使用该明确入口：委派原冻结 `cloudRes` 的所有登录/游戏目录行为，让 `get_version()` 返回真实当前版本、`get_hotfixes()` 返回空列表，并替换尚未调用的 `__main__.handle_update` 为“由启动器管理更新”的说明。这样不运行升级比较或 Qt 更新对话框，也屏蔽远程热更新供给；登录所需云端配置仍联网，不能把它描述成组件完全离线。策略拒绝未知版本/缺失控制点，下一次升级必须复核；helper 合约升为 8，旧 helper 会被界面判定需更新。

生成策略由 root-owned 状态工具每次受管启动前写入，路径在组件自己的状态目录，权限 0600。首次转换前的 config 保存在同目录 owner-only `config-before-launcher-update-policy.json`，不进入日志、源码或发行物；其内容可能含账号秘密。新配置只启用项目策略，历史云端 overlay 文件不删除，跨版本迁移备份继续保留。恢复旧行为须停止后台，恢复旧 helper/组件并恢复该私有 config；不能在活动代理中改写。

验证：原生状态工具 config/Hosts 自检、policy 精确源码执行测试（原模块委派、无更新/热修复供给、跳过自身 finder 防递归、未知版本拒绝）、helper readiness/job 合约测试。对已按清单核验的原始资产只读检查 PyInstaller CArchive/PYZ 表，确认 Python 3.12、包含 `cloudRes` 与 `hotfixmgr`，`buildinfo` 载荷包含当前精确 `v6.3.1-beta`。未执行归档代码、启动真实登录代理或系统授权；冻结加载机制和真实账号回归仍属候选安装验收，不能用单元测试替代。官方 `pack.yaml` 将 Release tag 写入 `buildinfo.VERSION`，本策略接受当前精确 beta tag。

## 公开许可边界

上游文件头授权 GPL-3.0-or-later，根 LICENSE 为 GPLv3 原文；本项目同样采用 GPL-3.0-or-later，继续独立保留上游出处与许可材料。公开材料正本见[第三方状态](../notices/THIRD_PARTY_STATUS.md)；本次没有新增上游二进制或 codeload archive 随包分发。上游归档包含网易 DLL/EXE 等未独立审计载荷，不能以 GPL 源码为由自动再分发整包。若以后捆绑/镜像登录组件或下载核心，闭包、对应源码、版权与再分发边界必须重新审核。
