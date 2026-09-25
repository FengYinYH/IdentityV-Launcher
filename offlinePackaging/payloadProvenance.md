# 离线整包的随包组件：来源与再分发边界

这份说明跟着包内 `OfflinePayloads/` 一起分发，记录「这个 App 比公开发行版多带了什么、为什么、以及这些字节是谁的」。

## 这个目录是什么

公开发行的第五人格启动器**不**携带下列组件，而是在首装时按固定 URL、大小和 SHA-256 从上游直接取得（原因见 `runtimeBootstrap/README.md` 与 `notices/README.md`）。离线整包面向网络环境只能访问网易的目标用户，GitHub 取不到，所以把这些字节提前放进 App。

启动器仍然逐个校验后才安装：`IdentityVRuntimeBootstrap` 校验基础镜像的大小与 SHA-256 之后才挂载并打补丁；`IdentityVDownloaderCoreBootstrap` 逐个校验三个 PE 文件；`IdentityVIdvLoginDownloader` 挂载内嵌磁盘映像取出 idv-login，并按**本次打包记录的**大小与 SHA-256 校验后才发布。任何一项不符都会失败并终止安装，不会退回网络、也不会写入半成品。

**idv-login 这一份被本项目重签过，请注意这是「修改过的版本」**：上游只提供 ad-hoc 签名，而 Apple 公证要求包里每个 Mach-O 都由 Developer ID 签名、带安全时间戳并启用 Hardened Runtime（公证会展开归档、连内嵌磁盘映像里的二进制也会逐个检查——我们已用最小包实测）。所以离线包在打包时用本项目 Developer ID 重签了这份上游二进制，并附加 PyInstaller 必需的三条 entitlements。**改动只有签名，没有改动任何一行上游代码。** 因为它仍是 GPL-3.0 覆盖的 idv-login 6.3.0 的修改版本，随包材料里保留了上游来源、许可与「这是一份被修改过的版本」的说明；对应源码以上游仓库 `KKeygen/idv-login` 的 v6.3.0-stable 标签为准。

上游原始字节的 `byteSize` / `sha256` 仍记录在 `offlinePayloads.json`，用来证明这份离线清单是从同一份上游锁派生的；实际分发的那一份的大小与哈希记在同文件的 `offlineByteCount` / `offlineSha256`。公开路径不受影响，它仍然下载并校验上游原始字节。

## 随包的三个组件

| 组件 | 包内位置 | 上游来源 | 原始字节 | SHA-256（前 16 位） |
| --- | --- | --- | --- | --- |
| 基础 Wine runtime 镜像 | `BaseRuntime.dmg` | `https://github.com/novak037/yanyun-on-mac/releases/download/v0.1.2/DWRG.dmg` | 326,791,695 | `69b79d250b794af8` |
| idv-login 6.3.0（装在内嵌磁盘映像里，本项目重签） | `idv-login-6.3.0.dmg` | `https://github.com/KKeygen/idv-login/releases/download/v6.3.0-stable/idv-login-v6.3.0-stable-mac` | 197,215,760（上游）/ 见 `offlinePayloads.json`（重签后） | `8e63be76de37b4ae`（上游） |
| 网易下载核心 | `netease-download-core/` | `https://raw.githubusercontent.com/KKeygen/idv-login/9b1ff598da6cb9ae6a952a8978ccf88bc8b2ae5c/binaries/` | 见下 | — |

网易下载核心三个文件：

| 文件 | 字节 | SHA-256（前 16 位） | 签名主体 |
| --- | --- | --- | --- |
| `downloadIPC.exe` | 34,378,168 | `5c11d3188d271c1d` | NetEase (Hangzhou) Network Co., Ltd |
| `OrbitSDK.dll` | 8,287,224 | `b46c0f57bcf2c7b1` | NetEase (Hangzhou) Network Co., Ltd |
| `aria2c.exe` | 5,607,360 | `76f1052d42ca0465` | 上游 aria2 构建 |

机器可读的同一份记录在 `offlinePayloads.json`，由 `offlinePackaging/stageOfflinePayloads.command` 从三份发行清单正本算出。

## 再分发边界（维护者必读）

- **基础 Wine runtime** 是 CodeWeavers/CrossOver 衍生的预编译 Wine bundle，来自 novak037 的 GitHub Release。上游没有把该 runtime 授权给本项目重新分发；公开路径一直靠「让用户从原发布者下载」来回避这一点。**离线整包把这一条从「从上游取」改成了「本项目再分发」，是发行方主动承担的取舍。**
- **idv-login** 采用 GPL-3.0，再分发需要随附对应源码与许可；上游源码归档本身包含网易的 PE 二进制，不能借「完整源码」名义把它当源码再分发。
- **网易下载核心** 是网易的闭源二进制（`observedAuthenticodeLeaf` 记录为 NetEase (Hangzhou) Network Co., Ltd），其再分发条件不在本项目掌握之内。
- 因此：**离线整包只作私人一次性交付，不作为公开下载物。** 公开发行仍走 `releasePackaging/buildAlpha1Preview.command`，它的载荷审计会继续拒绝 `DWRG.dmg`、`idv-login-v*-mac`、`downloadIPC`、`aria2`、`Orbit` 等名称。若将来要把随包组件做成公开物，必须重新做完整的第三方闭包审计与许可履行，不能沿用本包结论。
- 无论哪种包，**游戏本体都不随包分发**；用户仍在启动器里从网易官方 CDN 下载。
