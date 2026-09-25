# 离线整包（私有交付）

这个目录生成一份**只给具体某个人用**的安装包：除了游戏本体，其余组件都提前包进去，
让网络环境只能访问网易的用户也能一路装完。它不是公开发行路径，也不替代公开发行路径。

## 它和公开 DMG 的区别

| | 公开发行（`releasePackaging/buildAlpha1Preview.command`） | 离线整包（本目录） |
| --- | --- | --- |
| 基础 Wine runtime | 不随包；首装从 `novak037/yanyun-on-mac` 的 GitHub Release 下载 326,791,695 字节的 `DWRG.dmg`，校验后解出 runtime | 随包带同一份 `DWRG.dmg` 字节，启动器校验后直接从包内解出 |
| idv-login 6.3.0 | 不随包；首装从 `KKeygen/idv-login` 的 GitHub Release 下载 197,215,760 字节的 arm64 Mach-O，按上游 SHA-256 校验 | 随包带**本项目重签过的**同一份代码（公证要求 Developer ID + 时间戳 + Hardened Runtime），装在内嵌磁盘映像里，启动器挂载取出后按本次打包记录的哈希校验 |
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

## 为什么 idv-login 由本项目重签，再装进内嵌磁盘映像

idv-login 上游只提供 **ad-hoc 签名**的 arm64 Mach-O，而 Apple 公证要求包里每个 Mach-O 都由
Developer ID 签名、带安全时间戳并启用 Hardened Runtime。第一次提交公证被拒的日志是：

```text
.../OfflinePayloads/idv-login-6.3.0.gz/idv-login-6.3.0
  The binary is not signed with a valid Developer ID certificate.
  The signature does not include a secure timestamp.
  The executable does not have the hardened runtime enabled.
```

公证会**展开归档逐个检查**。我们用最小 app 做了三种探针，结论一致：裸文件、`.gz`、乃至**内嵌
磁盘映像**里的未签名 Mach-O 都会被揪出来（`payload.dmg/unsigned-payload — The binary is not
signed`）。所以不存在「用容器躲开公证」这条路。

因此离线包按公证的要求办：打包时用本项目 Developer ID 重签这份上游二进制，
`--options runtime --timestamp` 加 PyInstaller 需要的三条 entitlements
（见 `idvLoginOffline.entitlements` 里为什么是这三条）。**不改任何一行上游代码**，只换签名。
重签后实测 `--help` 可正常启动，Python/mitmproxy 运行时完好。

重签会改变字节，而安全时间戳让签名不可复现，所以：

- 上游发布物的 `byteSize` / `sha256` 仍留在 `offlinePayloads.json` 里，用来证明这份离线清单确实
  从同一份上游锁派生；
- **实际随包分发的那一份**的大小与哈希记在同文件的 `offlineByteCount` / `offlineSha256`，
  由下载器通过 `--payload-manifest` 读出来当作生效的期望值；
- 公开路径完全不受影响：它仍然下载上游原始字节并按上游哈希校验。

装进内嵌磁盘映像的原因不再是躲公证，而是**让这一份字节在打包流程里保持稳定**：
`buildPlayerLauncher.command` 最后会由内到外整树重签，裸放在 `Resources` 里的 Mach-O 会被再签
一次、字节又变，本次记录的哈希就失效；放进映像后签名树不遍历它。运行时由
`IdentityVIdvLoginDownloader --payload-image` 用 `hdiutil` 只读挂载取出、逐个校验、
无论成败都卸载。

再分发层面的含义要写清楚：我们分发的是**经过重签的 GPL-3.0 上游产物**。GPL 允许这么做，
但必须在随包材料里说明「这是一份被修改过的版本、改的是签名不是代码」，并保留上游来源与许可。
该说明在 `payloadProvenance.md` 与包内 `来源与许可说明.md`。

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
| `stageOfflinePayloads.command` | 把校验过的组件写进 App 的 `Contents/Resources/OfflinePayloads/`，生成 `offlinePayloads.json` 与来源说明。idv-login 装进内嵌磁盘映像（原因见下一节） |
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

### 包内不含用户状态（2026-09-26 实测）

这份包只带产品代码与三个上游组件，**不含任何账号、登录态、cookie/token、证书、游戏 prefix、
安装记录或本机用户状态**。DMG 可见条目只有启动器、`Applications` 链接与使用说明；App 内新增的
只有 `Contents/Resources/OfflinePayloads/`。逐文件名扫描 `cookie/token/session/credential/
keychain/p12/pem/*.reg/installation.json` 没有命中用户数据（只有随包的 `products.json` 产品目录）。
账号与运行态在 `/Library/Application Support/IdentityVOnMac/…` 与
`~/Library/Application Support/IdentityVOnMac/Prefixes/…`，打包流程不读不写这些目录。

**已知残留（本轮有意未修）**：`Contents/Resources/RuntimePatches/gdi32.dll` 是 emoji2 候选的
自建载荷，保留了 DWARF 调试段，里面有 85 处
`/Users/xunfeng/codexDaily/local/diagnostics/identityV/…` 形式的构建机源码路径；它来自
`1.0.0-rc.1-test.2` 的候选构建，公开 RC1 的 `r1` 默认运行时不含它。这是**构建机路径**，
不是账号或凭据。2026-09-26 风吟判断本包只作一次性私人交付，决定本轮不改；但公开封包器的载荷
审计明确拒绝 `codexDaily`/`/Users/<name>/`，因此**做下一次公开发行前必须处理**，
步骤与验证要求见 [`../docs/knownIssues.md`](../docs/knownIssues.md)。

网易 `downloadIPC.exe` 里的 `C:/Users/weiyufeng/…` 是网易构建机路径，来自受哈希锁定的上游原件，
不是本项目能改的内容；`com.xunfeng.identityv.*` 是历史 bundle identifier（升级兼容契约）。
