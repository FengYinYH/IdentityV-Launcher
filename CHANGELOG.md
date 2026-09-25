# 版本变更记录

## 1.0.0-rc.1-test.2 离线整包（仅本机测试，CFBundleVersion 4）

2026-09-26 追加：面向**一位**网络环境只能访问网易的目标用户，生成一份私有「离线整包」。
运行时的行为、补丁与 test.2 完全一致（`r1-emoji2-audio1`），区别在于发行形态：

- App 的 `Contents/Resources/OfflinePayloads/` 里预先带了基础 Wine runtime 镜像（上游 `DWRG.dmg`
  的原始字节）、idv-login 6.3.0（gzip 存放）和网易下载核心三个文件。启动器优先使用包内字节，
  校验方式与联网路径完全相同（大小 + SHA-256，idv-login 还要解压还原后核对原始哈希），
  校验失败即失败，不回退网络。
- 因此首装不需要访问 GitHub：只访问网易即可装好 runtime、登录组件和下载核心，
  游戏本体仍由用户在启动器内从网易官方 CDN 下载。
- 封包走新入口 `offlinePackaging/buildOfflinePackage.command`，Developer ID 签名 + 公证 +
  staple；DMG 里另附一份给普通用户的使用说明。公开封包器的载荷审计**未改动**，
  公开发行物依旧不包含这三组字节。
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
