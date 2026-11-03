# 版本變更記錄

## 1.0.0-rc.4（待發布）

### 問題修正

修正首次安裝時預設目錄尚不存在，導致國服或國際服提示「所選安裝位置無法使用」的問題（[#2](https://github.com/FengYinYH/IdentityV-Launcher/issues/2)）。

下載核心回傳輔助狀態碼 `304` 時，不再被誤判為未知錯誤而中斷下載（[#3](https://github.com/FengYinYH/IdentityV-Launcher/issues/3)）。

## 1.0.0-rc.3

2026-10-09

### 邏輯調整

問題回饋聯絡信箱更新為 `FengYinYH@icloud.com`，專案公開倉庫統一使用 [FengYinYH/IdentityV-Launcher](https://github.com/FengYinYH/IdentityV-Launcher)。

## 1.0.0-rc.2

2026-10-05

### 新增功能

多語言支援，預設跟隨系統。支援簡體中文、繁體中文與 English。

音訊輸入輸出裝置跟隨系統預設裝置切換，不再綁死啟動時的裝置。

### 邏輯調整

國服與國際服首裝、校驗修復共用網易下載核心。

IDV-Login 支援版本更新為 6.3.2 stable，更新由啟動器維護，關閉元件自己的升級與遠端熱修復。

預設遊戲目錄統一為 ASCII `IdentityV/CN`、`IdentityV/Global`，舊版預設目錄在遊戲退出後自動遷移。

卡死提醒隨啟動器持續啟用，移除選單開關。

遊戲視窗的選單列名稱調整為遊戲名稱第五人格，並跟隨語言變化。

### 問題修正

修正部分 emoji 無法正常顯示的問題。

## 1.0.0-rc.1

2026-09-23 公開發布。包含啟動器與第一方安裝、執行時下載和遊戲啟動的首個發布候選。公開包預設使用 `wine11-codeweavers-26.1-dxmt-0.80-macos15-alpha1-r1`；倉庫裡的 emoji2 修正當時只是本機維護候選，沒有進入該預設執行時。

已知問題（發布後確認）：聊天中部分組合 emoji 顯示為方框；遊戲內語音訊息使用內建麥克風錄製後，自己回聽時約每三秒出現破音。診斷與後續方案見[已知問題](docs/knownIssues.md)。

計畫中的功能（不屬於 RC1 已交付內容）：

- UI 重構
- Metal FX 超解析與補幀支援
- 跟隨系統設定的音訊裝置熱切換
- 遊戲多開（後續計畫，非優先項）
