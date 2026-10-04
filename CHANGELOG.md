# 版本变更记录

## 1.0.0-rc.2（准备中，尚未公开发布，CFBundleVersion 5）

启动器支持简体中文、繁体中文和English，默认跟随系统；菜单选择会保留，不改变游戏语言。项目介绍也提供三语言，默认简中，顶部可切换。

国服与国际服首装、校验修复共用网易下载核心；IDV Login仍是可选登录插件，不装也能下载、修复和玩。登录插件固定官方6.3.1 beta，更新由启动器维护，关闭组件自己的升级与远程热修复。

默认游戏目录统一为ASCII `IdentityV/CN`、`IdentityV/Global`。新的Wine运行包实现输入/输出分别跟随系统默认设备，保留旧audio1回退；本机已确认双向切换生效，精确耗时和更多设备组合尚未量化。卡死提醒随启动器持续启用，去掉菜单开关，既有检测与人工恢复语义不变。

游戏宿主菜单通过 CodeWeavers loader 的既有入口显示“第五人格”或“Identity V”，只传给最终游戏子进程，不修改上游签名或隐藏 Wine / CodeWeavers 来源。子进程范围与 Windows 启动参数合约通过，实际菜单效果留待下一次游戏启动确认。

GDI构建路径已从源码重建清理，接口审计与31项/3349项隔离emoji回归通过，正式出货审计通过。启动反馈区分准备、后台进程与真实窗口，等待期间保持操作忙状态，无窗口报IDV-LAUNCH-204，不自动重发启动。本机迁移漏改的受管 `Y:` 映射已修正，纯ASCII路径约10秒出窗口，不保留旧目录别名。国际服共享核心真实写入官方清单文件并通过双hash复验；修复路径按产品选择国服/国际服的独立Windows根，避免写错目录。具体边界见[已知问题](docs/knownIssues.md)；本段不代表GitHub已发布。

## 玩家游戏数据默认目录统一为 ASCII 路径（2026-10-04，未公开发布）

国服与国际服目录分别默认为 `~/Library/Application Support/IdentityV/CN` 和 `~/Library/Application Support/IdentityV/Global`。本机维护安装将原中文目录原地改名，并同步安装记录与游戏链接；保留配置备份和回退清单，不复制或重新下载游戏。产品不增加中文路径 fallback 或目录扫描功能，不改变 App 名称、bundle ID 或 `IdentityVOnMac` 身份目录。自定义目录和发现已有游戏留待后续版本。路径决策和适用边界见[第一方身份说明](docs/firstPartyIdentity.md#用户数据权限和升级)。

## 启动器三语言与固定登录更新策略（2026-10-04，未公开发布）

启动器新增简体中文、繁体中文与英文；默认跟随系统，菜单栏选择持久化，只影响启动器界面。语言归属、资源与可维护边界见[语言说明](docs/launcherLocalization.md)。

IDV Login 继续锁定官方 6.3.1 beta 原始资产，通过受管启动策略关闭自带更新检测入口与远程热修复供给；登录云端数据继续工作，旧 helper 必须更新为合约 8。来源依赖、实测 SHA、限定源码比较及许可/恢复边界见[来源审计](docs/idvLoginSourceAudit.md)。个人维护安装使用经 Developer ID 签名和公证的候选，发行号保持原值。

本轮候选分工和最小剩余验收见[候选验收边界](docs/launcherNextCandidateVerification.md)。现有GDI调试路径残留仍是公开发行前必要处理项；性能优化、气泡音根因与其他未来功能不自动成为1.0门槛。

## 国服与国际服共用游戏内容下载核心（本机候选，未发布）

国际服首装和完整性修复现接入与国服相同的网易 `downloadIPC.exe`、manifest planner 和下载后校验流程，并明确传入海外服务标志。国际服 adapter 继续解析、校验其官方清单与安装器地址，国服和国际服的发布事务仍分别管理。上游源码依据、取舍和未验证边界见[共链说明](docs/downloadCoreUnification.md)。

## Wine CoreAudio 默认输入/输出跟随（2026-10-04，本机默认，未公开发布）

Wine 播放和采集流现分别跟随 macOS 默认输出和默认输入；只读单个默认设备属性，每 100ms 轮询，失败后保留 Windows stream 并重试，切换恢复时清除旧音频积压。已部署为本机默认 immutable runtime，audio1 保留为回退版本。x86_64 模块 minimum OS 为 macOS 10.15；导出符号、install name 和动态依赖与 audio1 候选一致。没有真实设备切换或游戏内语音测试；100ms 是检测间隔，不代表实测恢复时长，也未验证约 1–2 秒静音目标。该版本尚未公开发布。设计、源补丁和验证边界见[默认设备跟随说明](docs/audioDefaultDeviceFollowing.md)。

## IDV Login 6.3.1 beta（2026-10-03，已本机安装，未公开发布）

启动器锁定官方 `v6.3.1-beta` 原始 arm64 组件，同步下载校验、界面与缓存常量、许可来源。沿用跨版本配置备份和旧热修复隔离；没有加入新版功能或优化。默认安装仍保护活动游戏；仅显式维护参数在代理及托管 hosts 已停止后允许保留游戏更新，见[组件说明](idvLoginComponent/README.md)。

下载器 Go 合约测试、完整启动器构建和签名树/部署目标检查通过，启动器已公证并 staple，安装版 Gatekeeper 为 Notarized Developer ID。更新后界面显示 6.3.1 已安装、登录后台停止，活动游戏进程保持；新版真实登录和新功能尚未验证。

## 维护者工具箱游戏声音短录候选（2026-09-28，本机候选，未安装）

新增独立、手动启动的第五人格游戏声音短录，最长 30 秒，支持手动停止保存，并在游戏/工具箱退出时收尾。音频来自按游戏窗口 owner 过滤的 ScreenCaptureKit 流，仅注册音频输出；输出为 48 kHz、16 位立体声 WAV 与目标身份、时间和格式 JSON 元数据。没有样本时不报告成功。维护说明和 Apple 过滤规则依据见 [工具箱说明](maintenanceToolboxApp/README.md#游戏声音短录)。

候选已通过完整工具箱构建与合成 PCM WAV 校验；真实 Wine 游戏声音是否按目标 PID 正确过滤、文件能否回听及听感变化仍待实机验收。本条不改变玩家启动器、Wine、游戏或 `/Applications` 安装版本。

## 1.0.0-rc.1-test.2 离线整包（仅本机测试，CFBundleVersion 4）

2026-09-26 追加：面向**一位**网络环境只能访问网易的目标用户，生成一份私有「离线整包」。
运行时的行为、补丁与 test.2 完全一致（`r1-emoji2-audio1`），区别在于发行形态：

- App 的 `Contents/Resources/OfflinePayloads/` 里预先带了基础 Wine runtime 镜像（上游 `DWRG.dmg`
  的原始字节）、idv-login 6.3.0（装在内嵌磁盘映像里）和网易下载核心三个文件。启动器优先使用包内
  字节，校验方式与联网路径完全相同（大小 + SHA-256，idv-login 还要取出后核对原始哈希），
  校验失败即失败，不回退网络。
- idv-login 之所以由本项目重签后再装进内嵌磁盘映像：上游只有 ad-hoc 签名，而 Apple 公证要求包里
  每个 Mach-O 都由 Developer ID 签名并带时间戳与 Hardened Runtime，且公证会展开归档、连内嵌
  磁盘映像里的二进制也逐个检查（已用最小包实测）。改动只有签名，没有改任何一行上游代码；
  重签后实测 `--help` 可正常启动。映像内的那一份因此字节不同，其大小/哈希由本次打包写进包内
  `offlinePayloads.json` 的 `offlineByteCount`/`offlineSha256`，下载器用 `--payload-manifest`
  读取；上游原始哈希仍留在同一份清单里作为派生依据。原因、边界与「这是一份被修改过的
  GPL 版本」的说明记在 `offlinePackaging/README.md` 与 `payloadProvenance.md`。
- 因此首装不需要访问 GitHub：只访问网易即可装好 runtime、登录组件和下载核心，
  游戏本体仍由用户在启动器内从网易官方 CDN 下载。
- 封包走新入口 `offlinePackaging/buildOfflinePackage.command`，Developer ID 签名 + 公证 +
  staple；DMG 里另附一份给普通用户的使用说明。公开封包器的载荷审计**未改动**，
  公开发行物依旧不包含这三组字节。
- **已知残留**：包内 `RuntimePatches/gdi32.dll`（emoji2 自建候选）保留了 DWARF 调试段，含 85 处
  构建机源码路径。不含账号、凭据或用户状态；本次一次性私人交付
  决定不改，但公开封包器的审计会拒绝这些字符串，**下一次公开发行前必须去除调试段并同步
  runtime 哈希/版本**，见[已知问题](docs/knownIssues.md)。
- **这一条是私有交付，不是新候选**：随包的基础 runtime 与网易组件不由本项目持有再分发授权，
  边界与来源见 `offlinePackaging/payloadProvenance.md`。公开发行号仍停在 `1.0.0-rc.1`，
  `1.0.0-rc.2` 的范围与时间未定。

随包组件的可用性验证见 `offlinePackaging/README.md` 的验收边界；「表情与语音条在游戏内是否
真的修好」仍属实机验证，不是打包结论。

## 1.0.0-rc.1-test.1（仅本机测试，已由 test.2 替代）

2026-09-24 安装。将 emoji2 候选 runtime 设为本机构建默认项，加入 AMD64 `gdi32.dll` 和 OFL emoji 字体，供验证游戏聊天组合 emoji。首次启动游戏还会按 manifest 下载上游基础 runtime。语音源补丁已合并到源码，但缺少可部署到当前 x86_64 runtime 的构件，未包含在此次运行时行为中。本条不代表公开发布；公开 `1.0.0-rc.1` 不变。

## 1.0.0-rc.1-test.2（仅本机测试）

2026-09-24 后续迭代：在 `emoji2` 的 GDI 与 OFL 字体候选上增加按转换器实际产出帧数写入的 CodeWeavers 26.1 CoreAudio 模块，构成新的 `r1-emoji2-audio1` 隔离 runtime。模块已用 x86_64 构建并由本项目 Developer ID 签名；是否修复语音条回听破音仍待风吟实机验证。r1 目录、已有 prefix 和公开 RC1 均不覆盖或改写。

## 1.0.0-rc.1

2026-09-23 公开发布。包含启动器与第一方安装、运行时下载和游戏启动的首个发布候选。公开包默认使用 `wine11-codeweavers-26.1-dxmt-0.80-macos15-alpha1-r1`；仓库里的 emoji2 修复当时只是本机维护候选，没有进入该默认运行时。

已知问题（发布后确认）：聊天中部分组合 emoji 显示为方框；游戏内语音消息使用内置麦克风录制后，自己回听时约每三秒出现破音。诊断与后续方案见[已知问题](docs/knownIssues.md)。

计划中的功能（不属于 RC1 已交付内容）：

- UI 重构
- Metal FX 超分插帧支持
- 跟随系统设置的音频设备热切换
