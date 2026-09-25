# 离线整包（私有交付）

这个目录生成一份**只给具体某个人用**的安装包：除了游戏本体，其余组件都提前包进去，
让网络环境只能访问网易的用户也能一路装完。它不是公开发行路径，也不替代公开发行路径。

## 它和公开 DMG 的区别

| | 公开发行（`releasePackaging/buildAlpha1Preview.command`） | 离线整包（本目录） |
| --- | --- | --- |
| 基础 Wine runtime | 不随包；首装从 `novak037/yanyun-on-mac` 的 GitHub Release 下载 326,791,695 字节的 `DWRG.dmg`，校验后解出 runtime | 随包带同一份 `DWRG.dmg` 字节，启动器校验后直接从包内解出 |
| idv-login 6.3.0 | 不随包；首装从 `KKeygen/idv-login` 的 GitHub Release 下载 197,215,760 字节的 arm64 Mach-O | 随包带同一份字节（gzip 存放），启动器解压后校验原始大小与 SHA-256 |
| 网易下载核心 | 不随包；从 `raw.githubusercontent.com` 取 `downloadIPC.exe` / `OrbitSDK.dll` / `aria2c.exe` | 随包带同一份三个文件 |
| 游戏本体 | 用户自己在启动器里下载 | 一样，用户自己在启动器里下载 |
| 载荷审计 | 拒绝 `DWRG.dmg`、`idv-login-v*-mac`、`downloadIPC`、`aria2`、`Orbit` 等名称 | 允许上面三组字节，仍然拒绝游戏本体（`.pak`/`.ucas`/`.utoc` 等） |
| DMG 内容 | App + Applications 链接 | App + Applications 链接 + 使用说明.rtf |
| 签名/公证 | Developer ID + 公证 + staple | 一样 |

**为什么另开一条路径而不是给公开脚本加开关**：这两个策略是互斥的。把开关塞进公开封包器，
等于给「公开包带着被禁止的载荷溜出去」留了一条路。公开路径的审计保持原样不动，离线整包
自己有一份更窄的审计：只允许三组明确列出的字节，其余一律拒绝。

**命令行层面公开包不会变胖**：`buildPlayerLauncher.command` 只在调用方显式设置
`IDENTITYV_OFFLINE_PAYLOAD_ROOT` 时才注入 `OfflinePayloads/`。不设置这个变量的构建，
App 里不会出现这个目录，公开封包器的载荷审计照旧通过。

## 再分发边界（重要）

上游没有把基础 runtime 与本项目再分发授权交给我们。公开发行路径一直靠「让用户从原发布者
下载」回避这一点，离线整包把这条改成了「本项目再分发」，因此：

- 离线整包**只作私人一次性交付**，不放到公开下载位置，不作为公开发行物登记版本。
- 随包的组件来源、字节与哈希，以及每一项为什么可以/不可以在公开场景分发，写在
  [`payloadProvenance.md`](payloadProvenance.md)；它会以 `来源与许可说明.md` 随载荷进入 App。
- 如果将来要把随包组件做成公开物，必须重新做完整的第三方闭包审计与许可履行，不能沿用本包结论。

## 怎么跑

前置条件：登录钥匙串里有 Developer ID Application 证书；公证凭据已按
`signing/setupNotaryCredentials.command` 存入（profile 默认 `fengyin-notary`）；
源码树在构建前是**干净的已提交状态**（`releaseIdentity.py verify` 会拒绝脏树构建的 App）。

```zsh
export PATH="/opt/homebrew/bin:$PATH"
export IDENTITYV_NOTARY_PROFILE=fengyin-notary

# 1) 把三个上游组件落到 local/offlinePayloads/ 并逐个校验（载荷目录被 git 忽略，不入库）
./offlinePackaging/prepareOfflinePayloads.command

# 2) 重建 App（自动注入 OfflinePayloads）、签名、公证、生成 DMG、只读挂载复验
./offlinePackaging/buildOfflinePackage.command

# 只想复用已经注入过载荷的既有 App：
./offlinePackaging/buildOfflinePackage.command --no-rebuild
```

产物（默认 `offlinePackaging/build/`）：

- `第五人格启动器-<版本>-离线整包.dmg`（Developer ID 签名 + 公证 + staple）
- `第五人格启动器-<版本>-离线整包-SHA256SUMS.txt`
- `第五人格启动器-<版本>-离线整包-使用说明.md`（同一份说明也以 RTF 形式放在 DMG 里）

## 目录里的东西

| 文件 | 职责 |
| --- | --- |
| `prepareOfflinePayloads.command` | 取得 + 校验三个上游组件到 `local/offlinePayloads/`。来源与哈希全部从三份发行清单正本读取，不另建一份登记表 |
| `stageOfflinePayloads.command` | 把校验过的组件写进 App 的 `Contents/Resources/OfflinePayloads/`，生成 `offlinePayloads.json` 与来源说明。idv-login 压成 gzip（原因见脚本头注释：裸 Mach-O 会被整树重签改字节，与锁定的 SHA-256 冲突） |
| `verifyOfflinePayloads.command` | 独立复核：三个组件逐字节对上发行清单，且 App 内除白名单外没有游戏 payload。打包前和 DMG 挂载后各跑一次 |
| `offlineDmgSettings.py` | Finder 布局：App + Applications + 使用说明，背景沿用公开发行的箭头图 |
| `使用说明.txt` | 给目标用户的四步说明与常见问题，打包时转成 RTF 放进 DMG |
| `payloadProvenance.md` | 随包组件的来源、许可与再分发边界 |
| `buildOfflinePackage.command` | 全流程入口：准备载荷 → 重建 → 校验身份 → 签名公证 App → 生成 DMG → 只读复验 → 签名公证 DMG → 发布产物 |

## 验收边界

只读挂载复验能证明：三个载荷真的穿过了 DMG 生成与压缩、签名树完整、DMG 可见布局正确、
App 内没有游戏本体。它**不能**证明的：

- 目标用户的网络真的只能访问网易。这需要在目标环境实测首装：runtime 解出、idv-login 装好、
  网易下载核心就位、游戏开始下载。
- 目标机器的 macOS 版本、Apple 芯片型号与可用磁盘空间是否满足。游戏本体十几 GB，
  加上 runtime 约 810 MB，安装盘至少需要 20 GB 余量。
- 游戏内功能（表情、语音条）是否真的被 emoji2 + audio1 补丁修好。这属于实机验证，不是打包结论。
