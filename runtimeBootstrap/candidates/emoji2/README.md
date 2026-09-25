# emoji2 隔离安装候选

此目录的 manifest 从公开 RC1 的 r1 输入派生，但使用独立不可变版本名 `wine11-codeweavers-26.1-dxmt-0.80-macos15-alpha1-r1-emoji2`。它保留四枚已签 Mach-O 补丁，并增加 `gdi32.dll` 的 x86_64 PE 补丁。2026-09-24 起，本地测试构建 `1.0.0-rc.1-test.1` 临时把它设为默认 runtime，以便风吟验证游戏聊天；公开 RC1 的 Git tag、包和默认引擎仍保持 r1。不要据此把它当作公开发行候选。

候选 GDI 由 CodeWeavers 26.1 对应源码加 [`wineEmojiPatch`](../../../wineEmojiPatch/README.md) 的两份补丁构建，SHA-256 `3aa45d33ab949a188f3249d0a6ecdb7793f141eefa10d631e404dfe78464de48`。候选字体是 Noto Sans CJK SC + Noto Emoji 的 OFL 派生字体，SHA-256 `c002488492344453723dc491ecbe2646018f94a3060a8d0cb5829ef8b4d0d45b`。manifest 校验下载源的原始 GDI hash `3069d43300df2d0d054fbb4d4641f0b412032a11384a6c534009fd92b0ba98ac`，安装后校验补丁 hash；`runtimeBootstrap` 还检查它确是 PE AMD64 DLL，避免拿 Mach-O 检查套在 Windows DLL 上。

隔离安装时在仓外新建 patch-root，复制 `runtimeBootstrap/releasePayloads/` 中四枚已签补丁与 `wineEmojiPatch/releasePayloads/gdi32.dll`，再把本目录 manifest、该 patch-root 和全新 destination-root 传给 `IdentityVRuntimeBootstrap install`。不要把 candidate 的 `current` 链接、runtime binding 或游戏 prefix 指向日常安装。已用 r1 的独立 APFS clone 替换 GDI 后执行 `verify-tree`，结果通过；字体与 GDI 的 `compositeRegression` 31 组行为用例失败 0。此前直接拿 9 月旧候选 runtime 验证失败在 `winemac.so` hash，因为它不是 RC1 的已签补丁字节；不能用旧候选冒充这一份 manifest。

**进入公开发行前仍需**：实际游戏聊天回归、候选安装/升级/回退路径、把字体放进最终 runner App 并核对哈希与 OFL notice、更新 Wine 对应源码和构建材料、从干净提交构建且换用新发行号。语音破音另有独立问题；`emoji2` 本身不包含音频源补丁。

后续 `emoji2-audio1` 是单独的本机测试 runtime：保留这里的 GDI/字体组合，并加入按实际产出帧数写入的 CoreAudio 补丁。它使用新的不可变版本目录，不能覆盖本候选或公开 RC1；是否改善约三秒破音仍待真实游戏回归。
