# 聊天 emoji 的 GDI 修复候选

2026-09-10：第五人格聊天将完整 UTF-16 emoji 传给 `DrawTextExW`，CodeWeavers 26.1 的普通 LTR 路径却跳过 shaping，最终分别画出两个 missing glyph。第一份补丁修复有效代理对；第二份补丁继续修复合法 emoji 组合的分段、替换和宽度计算。**2026-09-23 公开 RC1 仍默认使用 r1，未包含这个 emoji2 修复，故公开版本复发。**下文保留原因、反证、适用范围和复现入口；私人截图与原始日志不随仓。

## 维护时先读：原因与取舍

本次代码提交为 `59a67d3a`（基本代理对排版与启动器校验）、`38272664`（组合排版、生成器与回归）；`527abb71` 记录基本表情实机验收。以下摘要解释最终实现，排查记录保存具体实验，不需要重新从截图猜根因。

| 修改位置 | 为什么需要 | 实现与维护边界 |
| --- | --- | --- |
| 0001 / `gdi32/text.c` 的 `BIDI_Reorder` | 实际 trace 确认游戏传入完整代理对，Wine 普通 LTR 提前退出排版，两个编码单元各画 glyph 0 | 有效代理对进入既有 shaping；保持 LTR，孤立代理项不拼接。单纯加字体不能替代此修复 |
| 本机字体生成器与 catalog 的 `fontConfiguration` | 此路径的 ScriptShape 不自动跨字体 fallback；普通汉字可以 fallback 不代表 emoji 的这条路径也可以 | 保留原字体字形/metrics，再补 Noto 字形和组合规则；启动时核对字体与 DLL 摘要，避免组件与字体不配套 |
| 0002 / `uniscribe/usp10.c` 与生成 header | VS16/ZWJ 和方向属性曾把合法组合拆成多段，GSUB 看不到完整输入 | 精确匹配 Unicode 15.1 序列并保持同一 run；不把任意相邻符号都强行合并。Unicode 表与字体规则应同步更新 |
| 0002 / `uniscribe/shape.c`、字体私有 `emji` feature | 原 Noto 的复杂 ccmp 在该 Wine 遇到未支持的 ContextSubst format 3，职业表情曾被画坏 | 将已验证的 Noto 排版结果转换为简单 LigatureSubst；默认 surrogate script 走 DFLT/emji，保留显式脚本选择 |
| 0002 / 连接符清理与 `text.c` glyph 复制 | 合成后 ZWJ 清理曾覆盖整个组合图形；GDI 又丢失 ScriptPlace 的零宽 advance，造成额外空隙 | 只保护已经合成的连接符；只将被清空的控制符换为验证过的空轮廓、零宽 glyph，不抹掉可见组合记号 |
| 0002 / `GetTextExtentExPointW` | 画出组合图形后，累计 dx 和总宽仍可能不同，聊天布局仍会错 | 修正累计 dx、nfit=NULL 时最大宽度处理；保留测量/对齐/混排回归，不能只看单个图标是否出现 |

已排除的路径：只装 Noto/SystemLink/Uniscribe fallback 注册表配置，仅修掉 E/L 额外框，未修 F–J；强制 RTL 虽能触发排版，却会改变方向；直接强开 Noto ccmp 曾出现零宽职业表情；prefix native override 和两种 WINEDLLPATH 配置在本环境未实际加载候选 DLL。以上是精确 CW26.1 环境的实测结论；换上游版本可以重评，但必须说明新的依据，不能当作尚未试过的默认方案重复执行。

以后升级 Wine、Noto 或 Unicode 数据，先检查上游是否已修同一行为，再决定重基或删除本地补丁。重新运行[复现说明](REPRODUCE.md)中的序列扫描与行为回归，审计原中文字形/metrics，并检查真实游戏 A–N、实际加载路径及 catalog 摘要。字体、DLL、序列表是配套版本；当前本机快照可恢复，公共发行仍需完成字体来源与安装集成。输入法偶发失效另有未决记录，不属于这个补丁已解决的范围。

## 当前范围

- 原 emoji2 `gdi32.dll` 为 SHA-256 `3aa45d33ab949a188f3249d0a6ecdb7793f141eefa10d631e404dfe78464de48`、2,170,880 bytes；它后来被发现含有构建机路径，不能作为新的公开候选。当前仓库载荷与RC2新默认engine已改用下述路径映射重建 `0f608a…`，旧engine hash保留用于识别/回退旧槽。
- 隔离 runtime 仅替换 `lib/wine/x86_64-windows/gdi32.dll`。原 r1 同文件 SHA-256 `3069d43300df2d0d054fbb4d4641f0b412032a11384a6c534009fd92b0ba98ac` 保持不变。prefix native override、两种 WINEDLLPATH 形态均没有实际采用新件，不能按这些方式安装。
- 3,349 条 Unicode 15.1 标准组合及 VS16 变体扫描全部通过，均为单个有效 glyph，分段与宽度检查失败 0。31 项行为回归覆盖普通中英、肤色、职业、家庭、旗帜、键帽、心火、混排、左右中对齐、RTL 相邻及孤立代理项，失败 0；已查看实际绘制图。
- 游戏候选选用独立 ID `wine11-codeweavers-26_1-dxmt-0_80-macos15-alpha1-r1-emoji2`，保留原 r1 为 lastKnownGood 和 emoji1 前一候选。它未成为发行默认，也未更新 DMG。
- 基本 emoji 的 06:19 实际聊天截图已确认 F–J 全部显示、E/L 无多余方框。07:07 组合修复安装，preflight/签名通过；07:08 游戏 PID 21374 确认实际加载 emoji2 的 gdi32 和 v6 字体。**07:12 风吟提供的真实聊天截图确认 K 无独立纹理块、M 职业合成、N 为 CN 旗形，A–J/L 保持正常，组合 emoji 实机验收通过。**

组合方案使用简单 GSUB LigatureSubst，避免当前 Wine 未支持的 Noto ContextSubst format 3；仅对标准组合匹配完整序列，再应用本地字体私有 `emji` feature。肤色采用单色外观，旗帜为国家代码的单色旗形。没有承诺彩色图标或未来 Unicode 的完整覆盖。

## 字体与分发边界

排版补丁仍需要选中字体本身覆盖 SMP；当前 Wine 的 ScriptShape 不会自动走 SystemLink。已在本机以 Arial Unicode MS 为底补入 Noto Emoji 的缺失字形，生成 `IdentityV Local Emoji Test`。最终 v6 SHA-256 为 `f782b20e17155e349347ca83fbcb99dea658b9614e5504c64b97faef13e336e8`。父协调者逐字验证原有 50,377 个字形的轮廓、宽度、行高和 38,917 个字符映射不变；最终总 glyph 数 52,345。

生成字体仅保存在本机 private/ignored 区与本机游戏 prefix，不能把这份含系统字体的派生文件提交或加入发行包。Noto Emoji 来源是 OFL 黑白版，SHA-256 `de6c18832938afc99caf132b39d6a30a19bac7f2e812e28db2535b4608d27551`。

2026-09-24 另用全 OFL 的 Noto Sans CJK SC 与 Noto Emoji 生成 `IdentityV Emoji CJK` 候选，SHA-256 `c002488492344453723dc491ecbe2646018f94a3060a8d0cb5829ef8b4d0d45b`。其 31 组隔离 Wine 行为回归通过；曾发现 CJK 子集漏掉 U+200B，使两个未合并 ZWJ 用例多一个空格宽，补入空零宽字形后归零。它尚未通过游戏内回归和发行安装链验收，因此不把“字体许可可分发”误写成“公开修复已交付”。生成步骤见[复现说明](REPRODUCE.md)。

启动器支持 catalog 的可选 `fontConfiguration`（`cjkFamily` / `cjkFilename` / `cjkSha256`），只接受 prefix Fonts 内非 symlink 的精确哈希文件；无该字段的原引擎保持原路径。缺文件或损坏时拒绝该候选，避免静默切回不能显示 emoji 的字体。catalog 同时校验新 gdi32。

## 复现与恢复

可移植补丁、基础/v6 字体生成器、Unicode 数据及测试源码见[复现说明](REPRODUCE.md)。原始 CodeWeavers 源码依次应用 0001、0002；0002 包含所需生成 header，字体始终从本机合法来源生成。

私人项目档案保留当时的构建日志与原始截图，不是复现本仓补丁的前置条件。工具链为 llvm-mingw 20251216、临时 arm64 Bison 3.8.2；Bison 原包 SHA-256 `9bba0214ccf7f1079c5d59210045227bcf619519840ebfa80cd3849cff5a5bf2`。只构建 gdi32 的 PE 目标，不用这一轮 configure 的 Unix feature detection 产出替换声音、TLS 或图形组件。

历史实机回退曾使用私人档案中的维护脚本恢复原安装 App、选中引擎、GDI 和字体别名；本仓不把那份针对旧现场的脚本当成可在新机器直接运行的工具。新的候选如需安装，须另行准备针对其实际版本的恢复步骤。

## 2026-10-05 RC2 路径映射重建

strip-only 不能清掉旧载荷 `.rdata` 中的用户目录与工作区标记；这一点已由独立剥除副本反证。新构建从 CodeWeavers 26.1.0 源码包重建，归档 SHA-256 为 `e4ec87d5821a009dd1f1d2e36ffe2e24b8fcbae9516375ea42f95a16928ab8fa`，只按顺序应用已审阅的 0001 与 0002（SHA-256 分别为 `0e893472e0e3a83d2080a2649eaf84e996d21ea311f548160af68186ad3b91e8` 和 `fbeefa7343eef5faf9af88c9527ca09e61a8797bca73afa4af4940a68edd4394`）。新建树的完整命令入口是 [`buildGdi32PathMapped.command`](buildGdi32PathMapped.command)。它要求调用者提供明确的外置卷挂载点、预期 UUID 与全新构建目录；构建目录必须处在该卷内，且卷标识不符时会在写入前退出。

该脚本锁定 llvm-mingw 20251216 的 Clang 21.1.8、交叉编译 wrapper 摘要与 Bison 3.8.2 摘要，使用 `-ffile-prefix-map`、`-fdebug-prefix-map`、`-fmacro-prefix-map` 和相对调试编译目录映射源码与构建树，再移除调试段。llvm-mingw 不包含 host `dlltool`；Wine 26.1 的 `winebuild` 提供 `--without-dlltool`，脚本只在隔离构建树内包装该选项。工具链原位置含空格，而 `winebuild` 会把目标编译器命令作为空格分隔的参数传递；脚本在构建树内复制一个轻量 GCC wrapper 并链接编译器，保证该命令路径不含空格。两项 workaround 都不改上游源码或原工具链。

剥除后的 RC2 隔离 GDI SHA-256 为 `0f608a883e86533cd6f79c007d40e43f017d13917d13a393f60b11a580e3051d`；未剥除构建的 SHA-256 为 `26a17e8f0db9a522e730c68158b0fadf32087bfcb487e0bf7d52e84ff2ad1854`。PE 检查与旧载荷相比确认 AMD64、Windows 6.0/子系统 6.0、7 个 section 的名称与 flags、全部 exports，以及按名称/真实 ordinal 归一化后的 imports 一致；named-import hint 会随重建变化，不是 ordinal。输出中的 `/Users/`、`codexDaily`、外置卷标记和具体输入工具路径扫描均为 0。编译输出 `.text` 原始哈希为 `a41b57f0d117f0509d12ae016940fbb8d83b1a2ff24a2c7273f808817756966a`，旧载荷对应哈希为 `8d3d1bcd1f259162f4eb4ca73d7a896110b82888c2e94f835b9dd6973733a96d`；源重建不以原始机器码逐字相等为验收门槛，差异保留为验证边界。重复构建的 PE 时间戳会改变整个文件 SHA，因此分发必须锁定实际经过检查的那份二进制摘要。

新二进制在只含旧 `r1-emoji2-audio1` runtime 副本的独立 WINEPREFIX 上通过 `compositeRegression`（31 项，失败 0）和 `compositeSweep`（3,349 条 Unicode 15.1 RGI/VS16 序列，失败 0）。运行时仅在 S690 测试副本中替换 x64 GDI；源 slot 与当前 binding 的 GDI SHA 均保持原值。测试覆盖字体装载、绘制、shape 与 GDI 宽度，不是游戏内验证；未启动游戏、未打开音频采集。CodeWeavers/Wine 被修改源码保留 LGPL-2.1-or-later 声明；本仓构建脚本遵循仓库 GPL-3.0-only，Unicode 序列数据继续按单独的 Unicode License v3 处理。
