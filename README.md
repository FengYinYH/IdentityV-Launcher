[简体中文](README.md) · [繁體中文](README.zh-Hant.md) · [English](README.en.md)

# 第五人格启动器 · IdentityV Launcher

第五人格启动器是让 Apple Silicon Mac 运行《第五人格》PC 互通版的非官方项目。此项目无需安装 Crossover，也不需要网易发烧游戏平台。你甚至可以用触控板玩。

> 本页介绍的是 `1.0.0-rc.2` 候选内容。候选仍在准备中，尚未公开发布；已经公开的 RC1 不包含这里列出的新功能，请以 GitHub Releases 实际发布的版本为准。

## 功能介绍

支持国服和国际服的下载、校验、启动、修复和卸载。两服使用各自的官方游戏清单，并共用网易下载核心与下载后完整性复验；下载中可以暂停、继续或取消。

全新安装默认使用 ASCII 目录：国服 `~/Library/Application Support/IdentityV/CN`，国际服 `~/Library/Application Support/IdentityV/Global`。已有安装按启动器记录的位置管理；启动器不会扫描其它目录或自动迁移游戏。

启动器支持简体中文、繁体中文和 English，默认跟随系统语言。菜单中的选择会保存，只影响启动器界面，不改变游戏语言。

支持游戏内键盘映射。游戏内 Command 映射为 Windows 的 Alt；MacBook 键盘的 F1–F9 与 Windows 对应键位效果一致，保留 F10–F12 的音量控制功能。不影响游戏外的键盘功能。

启动器运行期间会持续监测可能的卡死；关闭主窗口不停止监测，退出启动器后才停止。检测到异常时可一键重启，也可以切换到启动器窗口后重启。

支持原生分辨率渲染和全屏下的 macOS 游戏模式。

## 下载与安装

RC2 候选尚未公开发布，目前没有对应的公开下载文件。正式发布后请从 GitHub Releases 下载 `1.0.0-rc.2`，再按以下步骤安装：

基础运行环境为 Wine 11 / CodeWeavers 26.1。启动器按需从 novak037/yanyun-on-mac v0.1.2 的 `DWRG.dmg` 获取，并校验锁定的文件大小与 SHA-256；公开安装包不包含该文件。

1. 打开下载的磁盘映像，将“第五人格启动器.app”拖入“应用程序”。
2. 打开启动器，选择国服或国际服，点击下载游戏；启动器会自动完成下载和安装。
3. 点击启动游戏。

## IDV Login

IDV Login 是非必需的可选登录组件。没有安装它也可以下载、修复和游玩游戏，登录时使用游戏官方登录流程即可。

当前候选固定使用官方 `6.3.1 beta`。启动器会关闭该组件自己的升级检测和远程热修复供给，避免固定版本在运行中自行变化；这不影响其云端登录服务。候选构建和组件策略检查不等于真实账号登录验收，登录体验仍待验证。

## 注意事项

首次安装和启动可能会申请系统权限；需要管理员授权时，macOS 会显示系统提示。第五人格启动器不会收集或上传你的密码。

游戏内复制粘贴使用 Control+C 和 Control+V，而不是 Command+C 和 Command+V。

游戏音频跟随 macOS 当前默认输入和输出设备，已在本机候选中实测生效。切换耗时和不同设备组合尚未量化，不承诺无缝切换；语音消息气泡音仍是另一个已知问题。设备选择仍在 macOS“系统设置 → 声音”中进行。

超过 1 kHz 回报率的鼠标可能造成异常卡顿。外接键盘的 F 区映射也可能异常。

项目目标为 macOS 15 及以上；当前候选只在 macOS 27 上完成实机验证。部分构件的技术最低系统标记为 macOS 14，不代表完整产品已验证或承诺支持 macOS 14。

不提供稳定性、性能和不封号承诺。作者不为你的段位分、认知分、胜率、墨迹负责，尤其谨慎打排位。如果因此造成损失，可以找作者来自定义房间被螺旋鞭补偿。

## 反馈与开发

启动器可在本地生成脱敏诊断包，再交给邮件客户端；你可以检查内容后自行发送，启动器不会在后台上传。

维护项目请从[开发者指南](docs/developerGuide.md)进入；[项目地图](projectMap.md)列出目录和脚本职责，[工程取舍](docs/engineeringDecisions.md)解释设计原因。候选细节见[语言说明](docs/launcherLocalization.md)、[两服下载共链](docs/downloadCoreUnification.md)、[IDV Login 来源与策略](docs/idvLoginSourceAudit.md)和[音频设备跟随边界](docs/audioDefaultDeviceFollowing.md)。

原创代码采用 [GPL-3.0-or-later](LICENSE)；游戏及第三方组件遵循各自许可，见[第三方说明](notices/README.md)。

## 致谢

Wine 11 部分参考了 novak037 的实现。

IDV Login 由 Keygen 开发。
