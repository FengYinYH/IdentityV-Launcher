# 版本变更记录

## 1.0.0-rc.6

2026-11-07

### 简体中文

#### 调整

- 「关于」显示实际构建号；更新窗口沿用原生关于窗口的字体、图标和对齐，内容与按钮在下方自然展开。
- 游戏 Dock 图标采用圆角矩形外轮廓，保留原图内容。

#### 修复

- 修复部分网络环境下 IDV Login 域名解析失败、导致无法完成登录的问题。
- 修复游戏启动从小窗切换到最终 1080p 尺寸后未居中的问题。
- 修复 Dock 中游戏名称显示为「wine」的问题。
- 修复捕获模式高速移动时鼠标指针逸出游戏窗口，以及游戏位于后台时拉回指针的问题。
- 改善移动同时转动视角时的输入抖动，保持自由模式跨窗及切回游戏后的捕获恢复。
- 修复维护工具箱停止联合采集后的画面流、文件和状态收尾，避免迟到样本写入旧记录。

### 繁體中文

#### 調整

- 「關於」顯示實際建置號碼；更新視窗沿用原生關於視窗的字體、圖示與對齊，內容與按鈕在下方自然展開。
- 遊戲 Dock 圖示採用圓角矩形外輪廓，保留原圖內容。

#### 修復

- 修復部分網路環境下 IDV Login 網域解析失敗、導致無法完成登入的問題。
- 修復遊戲啟動從小視窗切換至最終 1080p 尺寸後未置中的問題。
- 修復 Dock 中遊戲名稱顯示為「wine」的問題。
- 修復擷取模式高速移動時滑鼠指標逸出遊戲視窗，以及遊戲位於背景時拉回指標的問題。
- 改善移動同時轉動視角時的輸入抖動，保留自由模式跨視窗及切回遊戲後的擷取恢復。
- 修復維護工具箱停止聯合採集後的畫面串流、檔案與狀態收尾，避免遲到樣本寫入舊記錄。

### English

#### Changed

- About now shows the actual build number. The update window uses the native About window's typography, icon and alignment, with content and buttons extending naturally below.
- Rounded the game's Dock icon corners while preserving the original artwork.

#### Fixed

- Fixed IDV Login DNS resolution failures that prevented login in some network environments.
- Fixed startup centering after the game expands from its initial small window to the final 1080p size.
- Fixed the game's Dock tooltip showing “wine” instead of its localized name.
- Fixed the pointer escaping the game window during fast movement in capture mode, and being pulled back by the game while it was in the background.
- Improved input jitter when moving and turning the camera together, while preserving free-mode movement across windows and capture restoration when returning to the game.
- Fixed visual-stream, file and status cleanup after combined recording stops in the maintenance toolbox, preventing late samples from entering an old recording.

---

## 1.0.0-rc.5

2026-11-04

### 简体中文

#### 新增

- 「版本与更新」接入实际更新检测和安装流程，不再只是一个预留按钮。
- 新增「自定义游戏位置」，也可通过此功能指向已经下载好的游戏目录；可选择文件或目录。
- 新增 CLI 及文档说明，Agent 可通过[命令接口](https://github.com/FengYinYH/IdentityV-Launcher/blob/v1.0.0-rc.5/docs/agentCLI.md)安装、检测、修复和管理游戏，读取任务状态、进度与日志；帮助菜单可打开本版文档、复制随包 `idv` 入口命令，无需另装全局命令。Agent 卸载游戏前需要用户确认。
- IDV Login 就绪时可使用「打开后台」进入本机管理页面；反馈窗口增加讨论组入口。
- Agent 可控制安装下载的暂停和继续，并使用已支持的语言、登录组件和反馈草稿接口。

#### 调整

- IDV Login 更新提示不再阻挡已安装组件的启动、停止、卸载和跟随设置，移除额外的上游更新屏蔽。
- 已有外部客户端的安装状态与基础清单检查结果分开显示；检查外部客户端不会自动覆盖其文件。
- 导入的外部游戏文件在卸载时保留。
- 缩短运行环境的实体目录名，并在安全条件下迁移旧目录；若 Wine 初始化仍遇到路径相关错误，显示明确诊断。

#### 修复

- 为 IDV Login 首次 CA 导入无法交互的情况增加有界恢复。
- 修复游戏进程已启动，但启动器因会话记录失败而误报启动失败的情况。
- 安装空间预检改用实际可用容量；下载核心明确报告空间不足时显示所需空间。
- 补齐卡死提示、恢复倒计时、麦克风用途及常见运行状态的三语言显示。
- 国际服首次安装长时间停在 0 KB：下载核心监督器在 Hardened Runtime 下拿不到 Wine 的 DYLD 库搜索路径，现按已选 Wine 的固定布局恢复 `lib64`，拒绝无效搜索路径并保留缺库诊断（[#4](https://github.com/FengYinYH/IdentityV-Launcher/issues/4)）。
- 下载核心的辅助通知或重复速率不再无限延长进度期限；清单下载重试耗尽的 304 会立即明确失败，并保留受限诊断；不根据任意文本猜测错误。
- 修复仅安装国际服或两服运行环境不同时的启动确认误报。
- 国际服游戏内更新后，基础清单修复也会保护有效热更新，避免回退正常客户端。
- 操作锁忙碌导致启动请求未执行时，显示单独的启动器错误代码和说明；后续同一产品成功启动会清除旧的失败提示。
- 修复 Agent 请求国际服清单时误用国服解析器的问题。

### 繁體中文

#### 新增

- 「版本與更新」接入實際更新檢查與安裝流程，不再只是預留按鈕。
- 新增「自訂遊戲位置」，也可透過此功能指定已下載的遊戲目錄；可選擇檔案或目錄。
- 新增 CLI 與指令文件，Agent 可透過[指令介面](https://github.com/FengYinYH/IdentityV-Launcher/blob/v1.0.0-rc.5/docs/agentCLI.md)安裝、檢查、修復及管理遊戲，讀取工作狀態、進度與日誌；說明選單可開啟本版文件、複製隨包 `idv` 入口指令，無須另裝全域指令。Agent 解除安裝遊戲前需要使用者確認。
- IDV Login 就緒時可使用「開啟後台」進入本機管理頁面；回饋視窗新增討論群組入口。
- Agent 可暫停及繼續安裝下載，並使用已支援的語言、登入元件與回饋草稿介面。

#### 調整

- IDV Login 更新提示不再阻擋已安裝元件的啟動、停止、解除安裝及跟隨設定，移除額外的上游更新封鎖。
- 既有外部用戶端的安裝狀態與基礎清單檢查結果分開顯示；檢查外部用戶端不會自動覆寫其檔案。
- 匯入的外部遊戲檔案在解除安裝時保留。
- 縮短執行環境的實體目錄名稱，並在安全條件下遷移舊目錄；若 Wine 初始化仍遇到路徑相關錯誤，顯示明確診斷。

#### 修復

- 為 IDV Login 首次 CA 匯入無法互動的情況加入有界恢復。
- 修復遊戲程序已啟動，但啟動器因工作階段記錄失敗而誤報啟動失敗的情況。
- 安裝空間預檢改用實際可用容量；下載核心明確回報空間不足時顯示所需空間。
- 補齊卡死提示、恢復倒數、麥克風用途及常見執行狀態的三語顯示。
- 國際服首次安裝長時間停在 0 KB：下載核心監督器在 Hardened Runtime 下取不到 Wine 的 DYLD 函式庫搜尋路徑，現依已選 Wine 的固定配置恢復 `lib64`，拒絕無效搜尋路徑並保留缺庫診斷（[#4](https://github.com/FengYinYH/IdentityV-Launcher/issues/4)）。
- 下載核心的輔助通知或重複速率不再無限延長進度期限；清單下載重試耗盡的 304 會立即明確失敗，並保留受限診斷；不依任意文字猜測錯誤。
- 修復僅安裝國際服或兩服執行環境不同時的啟動確認誤報。
- 國際服遊戲內更新後，基礎清單修復也會保護有效熱更新，避免回退正常用戶端。
- 操作鎖忙碌導致啟動請求未執行時，顯示獨立的啟動器錯誤代碼與說明；後續同一產品成功啟動會清除舊的失敗提示。
- 修復 Agent 請求國際服清單時誤用國服解析器的問題。

### English

#### Added

- Version & Updates now connects to update checking and installation flows instead of being a placeholder button.
- Added Custom Game Location, which can also point to an already downloaded game directory; both files and folders can be selected.
- Added a CLI and documentation so agents can install, inspect, repair and manage games through the [command interface](https://github.com/FengYinYH/IdentityV-Launcher/blob/v1.0.0-rc.5/docs/agentCLI.md), and read task status, progress and logs. The Help menu opens documentation for the installed version and copies the bundled `idv` entry command; no global command installation is needed. Agents must obtain user confirmation before uninstalling a game.
- Open Admin opens the local management page when IDV Login is ready; the feedback window also provides access to the discussion group.
- Agents can pause and resume installation downloads and use the supported language, login-component and feedback-draft interfaces.

#### Changed

- IDV Login update notices no longer block starting, stopping, uninstalling or configuring Start with Game for an installed component. The extra upstream update blocker has been removed.
- Installation status and base-manifest inspection results are shown separately for existing external clients. Inspection does not automatically overwrite their files.
- Imported external game files are preserved during uninstallation.
- Shortened physical runtime directory names and added migration of legacy directories when safe. Explicit diagnostics are shown if Wine initialization still encounters a path-related error.

#### Fixed

- Added bounded recovery when the initial IDV Login CA import cannot obtain user interaction.
- Fixed false startup failures caused by session recording after the game process had already started.
- Installation space checks use actual free space; required capacity is shown when the download core explicitly reports insufficient space.
- Added missing translations for hang alerts, recovery countdowns, microphone usage descriptions and common runtime status messages across all three languages.
- Fixed global first installs stalling at 0 KB when Hardened Runtime strips Wine's DYLD library search path. The download-core supervisor now restores `lib64` from the selected Wine layout, rejects invalid search paths and retains missing-library diagnostics ([#4](https://github.com/FengYinYH/IdentityV-Launcher/issues/4)).
- Auxiliary notifications and repeated transfer rates no longer extend progress deadlines indefinitely. Manifest retry exhaustion (304) now fails immediately with bounded diagnostics, without inferring errors from arbitrary text.
- Fixed launch confirmation errors in global-only installations and when the two clients use different runtimes.
- Base-manifest repair now protects valid in-game hot updates for the global client, preventing rollback of an otherwise working client.
- Launch requests blocked by a busy operation lock now show a distinct launcher error code and explanation. A later successful launch of the same product clears the previous failure message.
- Fixed Agent requests for the global manifest incorrectly using the mainland parser.

---

## 1.0.0-rc.4

2026-11-04

### 调整

- 简体、繁体与英文 README 增加 QQ 交流群。

### 修复

- 首次安装时默认目录尚不存在，导致国服或国际服提示「所选安装位置不可用」（[#2](https://github.com/FengYinYH/IdentityV-Launcher/issues/2)）。
- 下载核心返回辅助状态码 `304` 时不再被误判为未知错误并中断下载（[#3](https://github.com/FengYinYH/IdentityV-Launcher/issues/3)）。

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
