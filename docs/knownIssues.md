# 已知问题与当前边界

本页记录公开 RC1 后确认、需要后续版本处理的问题。版本与包的身份以[版本约定](../releasePackaging/versioning.md)和包内 `build-provenance.json` 为准；开发中的补丁不代表 RC1 已包含修复。

## 组合 emoji 显示方框

2026-09-23 公开 RC1 的游戏聊天中，部分组合 emoji 显示为方框；截图显示单个基础符号有些可见，后续组合项失效。RC1 的默认 Wine runtime 是 `wine11-codeweavers-26.1-dxmt-0.80-macos15-alpha1-r1`，没有选用仓库中的 emoji2 GDI 候选。原有 emoji2 加本机测试字体的隔离回归通过，但该字体含系统 Arial Unicode 字形，不能直接放入公开发行包。

2026-09-24，改用 OFL 来源的 Noto Sans CJK SC 与 Noto Emoji 构造可分发的单色字体候选，并在隔离 Wine prefix 上通过 `compositeRegression` 的 31 组基础、组合和边界用例；其中 U+200B 必须作为空的零宽字形显式保留，否则未合并 ZWJ 的 GDI 宽度会比 Uniscribe 多一个空格。这个结果只覆盖隔离字体与 GDI 路径；仍须验证游戏内聊天、安装后的新 runtime 切换和公开材料对应关系。复现入口见[emoji 修复](../wineEmojiPatch/README.md)。

## 语音消息回听定期破音

2026-09-23，使用 Mac 内置麦克风录制第五人格内的语音消息后，自己点开语音条回听时，约每三秒有一次气泡状破音；其他应用没有同类现象。当前只证明游戏内路径存在可感知问题，尚未证明是在 Wine 采集、游戏编码、播放或设备切换的哪一步产生。运行日志中的高音频设备延迟警告约每五秒出现，不应直接认定为三秒破音的原因。现场排查和后续分辨方法见[音频记录](audioCapturePeriodicArtifact20260924.md)。

当前游戏会话运行期间不改动其 Wine prefix 或应用安装物；需要新的录音、时间戳或游戏内复测时，等待玩家方便操作。
