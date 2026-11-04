# 版本变更记录

## 1.0.0-rc.5

2026-11-04

### 修复

- 国际服首次安装长时间停在 0 KB：下载核心监督器在 Hardened Runtime 下拿不到 Wine 的 DYLD 库搜索路径，现按已选 runtime 重建 `lib64` 并校验路径归属与 GnuTLS 文件（[#4](https://github.com/FengYinYH/IdentityV-Launcher/issues/4)）。
- 下载核心报告的终止性辅助状态（如 `304`）不再被静默忽略，会明确失败并显示错误；这类状态也不再延长下载进度期限。

### 修正

- 國際服首次安裝長時間停在 0 KB：下載核心監督器在 Hardened Runtime 下取不到 Wine 的 DYLD 函式庫搜尋路徑，現改為依已選 runtime 重建 `lib64`，並驗證路徑歸屬與 GnuTLS 檔案（[#4](https://github.com/FengYinYH/IdentityV-Launcher/issues/4)）。
- 下載核心回報的終止性輔助狀態（如 `304`）不再被靜默忽略，會明確失敗並顯示錯誤；這類狀態也不再延長下載進度期限。

### Fixed

- First install of the global build no longer stalls at 0 KB: under Hardened Runtime the download-core supervisor lost Wine's DYLD library path, so it now rebuilds `lib64` from the selected runtime and verifies the path stays inside that runtime and contains GnuTLS ([#4](https://github.com/FengYinYH/IdentityV-Launcher/issues/4)).
- Terminal auxiliary states reported by the download core (such as `304`) are no longer swallowed silently; they fail with a visible error and no longer extend the download progress deadline.

---

## 1.0.0-rc.4

2026-11-04

### 调整

- 简体、繁体与英文 README 增加 QQ 交流群。

### 調整

- 簡體、繁體與英文 README 新增 QQ 交流群。

### Changed

- QQ group added to the Simplified Chinese, Traditional Chinese and English READMEs.

### 修复

- 首次安装时默认目录尚不存在，导致国服或国际服提示“所选安装位置不可用”（[#2](https://github.com/FengYinYH/IdentityV-Launcher/issues/2)）。
- 下载核心返回辅助状态码 `304` 时不再被误判为未知错误并中断下载（[#3](https://github.com/FengYinYH/IdentityV-Launcher/issues/3)）。

### 修正

- 首次安裝時預設目錄尚不存在，導致國服或國際服提示「所選安裝位置無法使用」（[#2](https://github.com/FengYinYH/IdentityV-Launcher/issues/2)）。
- 下載核心回傳輔助狀態碼 `304` 時，不再被誤判為未知錯誤而中斷下載（[#3](https://github.com/FengYinYH/IdentityV-Launcher/issues/3)）。

### Fixed

- First install no longer fails with "the selected install location is unavailable" when the default directory does not exist yet ([#2](https://github.com/FengYinYH/IdentityV-Launcher/issues/2)).
- Auxiliary status code `304` from the download core is no longer treated as an unknown error that aborts the download ([#3](https://github.com/FengYinYH/IdentityV-Launcher/issues/3)).

---

## 历史版本

## 简体中文

### 1.0.0-rc.3

2026-10-09

#### 调整

- 问题反馈联系邮箱更新为 `FengYinYH@icloud.com`，项目公开仓库统一使用 [FengYinYH/IdentityV-Launcher](https://github.com/FengYinYH/IdentityV-Launcher)。

### 1.0.0-rc.2

2026-10-05

#### 新增

- 多语言支持，默认跟随系统：简体中文、繁体中文和 English。
- 音频输入输出设备随系统默认设备切换，不再绑死启动时的设备。

#### 调整

- 国服与国际服首装、校验修复共用网易下载核心。
- IDV-Login 支持版本更新为 6.3.2 stable，更新由启动器维护，关闭组件自己的升级与远程热修复。
- 默认游戏目录统一为 ASCII `IdentityV/CN`、`IdentityV/Global`，旧版默认目录在游戏退出后自动迁移。
- 卡死提醒随启动器持续启用，去掉菜单开关。
- 游戏窗口的菜单栏名称调整为游戏名称第五人格，随语言变化。

#### 修复

- 修复了一些 emoji 无法正常显示的问题。

### 1.0.0-rc.1

2026-09-23 公开发布。包含启动器与第一方安装、运行时下载和游戏启动的首个发布候选。公开包默认使用 `wine11-codeweavers-26.1-dxmt-0.80-macos15-alpha1-r1`；仓库里的 emoji2 修复当时只是本机维护候选，没有进入该默认运行时。

已知问题（发布后确认）：聊天中部分组合 emoji 显示为方框；游戏内语音消息使用内置麦克风录制后，自己回听时约每三秒出现破音。诊断与后续方案见[已知问题](docs/knownIssues.md)。

计划中的功能（不属于 RC1 已交付内容）：

- UI 重构
- Metal FX 超分插帧支持
- 跟随系统设置的音频设备热切换
- 游戏多开（后续计划，非优先项）
---

## 繁體中文

### 1.0.0-rc.3

2026-10-09

#### 調整

- 問題回饋聯絡信箱更新為 `FengYinYH@icloud.com`，專案公開倉庫統一使用 [FengYinYH/IdentityV-Launcher](https://github.com/FengYinYH/IdentityV-Launcher)。

### 1.0.0-rc.2

2026-10-05

#### 新增

- 多語言支援，預設跟隨系統：簡體中文、繁體中文與 English。
- 音訊輸入輸出裝置跟隨系統預設裝置切換，不再綁死啟動時的裝置。

#### 調整

- 國服與國際服首裝、校驗修復共用網易下載核心。
- IDV-Login 支援版本更新為 6.3.2 stable，更新由啟動器維護，關閉元件自己的升級與遠端熱修復。
- 預設遊戲目錄統一為 ASCII `IdentityV/CN`、`IdentityV/Global`，舊版預設目錄在遊戲退出後自動遷移。
- 卡死提醒隨啟動器持續啟用，移除選單開關。
- 遊戲視窗的選單列名稱調整為遊戲名稱第五人格，並跟隨語言變化。

#### 修正

- 修正部分 emoji 無法正常顯示的問題。

### 1.0.0-rc.1

2026-09-23 公開發布。包含啟動器與第一方安裝、執行時下載和遊戲啟動的首個發布候選。公開包預設使用 `wine11-codeweavers-26.1-dxmt-0.80-macos15-alpha1-r1`；倉庫裡的 emoji2 修正當時只是本機維護候選，沒有進入該預設執行時。

已知問題（發布後確認）：聊天中部分組合 emoji 顯示為方框；遊戲內語音訊息使用內建麥克風錄製後，自己回聽時約每三秒出現破音。診斷與後續方案見[已知問題](docs/knownIssues.md)。

計畫中的功能（不屬於 RC1 已交付內容）：

- UI 重構
- Metal FX 超解析與補幀支援
- 跟隨系統設定的音訊裝置熱切換
- 遊戲多開（後續計畫，非優先項）
---

## English

### 1.0.0-rc.3

2026-10-09

#### Changed

- The feedback contact email is now `FengYinYH@icloud.com`, and the public repository is unified as [FengYinYH/IdentityV-Launcher](https://github.com/FengYinYH/IdentityV-Launcher).

### 1.0.0-rc.2

2026-10-05

#### Added

- Multilingual support following the system language: Simplified Chinese, Traditional Chinese and English.
- Audio input and output follow the system default device and switch with it, instead of staying bound to the device present at launch.

#### Changed

- Mainland and global first installs, verification and repair now share the same NetEase download core.
- IDV-Login support updated to 6.3.2 stable; the launcher manages updates and disables the component's own updater and remote hotfixes.
- Default game directories are unified to ASCII `IdentityV/CN` and `IdentityV/Global`; old default directories migrate automatically after the game exits.
- The hang reminder stays enabled together with the launcher; the menu toggle is removed.
- The game window's menu bar name is now the game name and follows the selected language.

#### Fixed

- Fixed some emoji not displaying correctly.

### 1.0.0-rc.1

2026-09-23 public release. The first release candidate with the launcher, first-party installation, runtime download and game launch. The public package defaults to `wine11-codeweavers-26.1-dxmt-0.80-macos15-alpha1-r1`; the emoji2 fix in the repository was only a local maintenance candidate at that time and was not part of that default runtime.

Known issues (confirmed after release): some combined emoji render as boxes in chat; in-game voice messages recorded with the built-in microphone crackle about every three seconds on playback. See [known issues](docs/knownIssues.md) for diagnosis and follow-up.

Planned features (not part of RC1):

- UI redesign
- Metal FX upscaling and frame interpolation
- Audio device following the system setting
- Multiple game instances (future plan, low priority)