# DXMT 0.80 的 macOS 14 向下兼容审计

**现行决定（2026-11-07）：所有者已取消 macOS 14 适配，不再安排后续施工；完整产品按 macOS 15+ 维护。** 以下是历史审计与当时备选路线，保留技术依据，不作为待办或支持承诺。

审计时间：2026-08-29。范围仅限活动 Wine 11 runtime 的只读 Mach-O/包闭包检查，以及来自 DXMT 官方 GitHub 的 `v0.80` 源码与构建说明。不修改 `installation.json`、`launcher.env`、App、活动 runtime 或 prefix。

## 结论

**不能为当前 Wine 11 + DXMT 0.80 runtime 声明 macOS 14 支持，也没有生成可激活的 DXMT 替换槽。**

DXMT 官方将 macOS Sonoma（14）列为 v0.80 的构建前提，但并不等于每一个编译产物都可在 14 上运行。活动包的 `winemetal.so` 自身最低版本为 **15.0**；更重要的是，官方 v0.80 源码对 Metal 3.2/AIR 明确设置 `air64-apple-macosx15.0.0`，并把相应的 Metal API 放在 `@available(macOS 15, *)` 门后。macOS 14 分支会限制到 Metal 3.1，但仍必须取得与 Wine ABI 匹配的完整交叉构建。

活动运行时另有 GMP、PCRE2、zstd 三枚 `minos 26.0` 依赖，因此即使单独重建 DXMT 成功，整槽也不能降为 macOS 14。完整闭包证据见 [macosCompatibilityAudit.md](macosCompatibilityAudit.md)。

## 活动 DXMT 包的事实

对象：维护者隔离的 `wine11-codeweavers-26.1-dxmt-0.80` runtime 中的 `lib/dxmt/x86_64-unix/winemetal.so`。

| 项 | 结果 |
| --- | --- |
| 格式 / 架构 | Mach-O 64-bit shared library / x86_64 |
| SHA-256 | `16e32803d0d25d3bb41d59e1560f00d0919d76c6fa9b21dbe0ef827bb213faf0` |
| `LC_BUILD_VERSION` | platform macOS，`minos 15.0`，SDK 15.1 |
| install-name | `@rpath/winemetal.so` |
| Wine ABI 依赖 | `@rpath/winemac.so`、`@rpath/ntdll.so` |
| Apple 图形依赖 | weak `Metal`，强 `MetalFX`，以及 CoreFoundation/Foundation/CoreGraphics/QuartzCore/AppKit/ColorSync |
| 其他依赖 | sqlite3、libSystem、zlib、ncurses、libxml2、libc++、libobjc |

未定义符号包含 `MTLFXSpatialScalerDescriptor` / `MTLFXTemporalScalerDescriptor`、Metal 的 binary archive / counter / mesh pipeline 类，以及 sqlite3 API；未发现旧 wiki 所称的 `macdrv_*` 未定义私有符号。`nm -gU` 有 15,258 个全局符号（它静态携带了大量 LLVM 导出，不能把该数误读为 Wine ABI 表面）。

包内文件共 15 枚：一个 x86_64 Unix `winemetal.so`、6 个 x86_64 Windows DLL、4 个 i386 Windows DLL，加 `nvapi64.dll` 与 `nvngx.dll`。所有文件的可复查哈希由 [auditDxmt080MacOS14Compatibility.command](auditDxmt080MacOS14Compatibility.command) 输出；该脚本只读，不会启动 Wine 或读取 prefix。

## 官方 v0.80 的来源与要求

从官方 `3Shain/dxmt` 的带注释 tag `v0.80` 以 `--recurse-submodules` 获取源码，tag 指向提交：`589adb780354b461645b29999cefaf533594ee99`。实测时使用隔离源码目录，本仓不保存维护者的本机路径。

官方 `docs/DEVELOPMENT.md` 的明确要求：

- macOS Sonoma 及以后；
- Meson 1.3+；
- **LLVM 15（精确 major）**，含 headers 和 static libraries；
- Xcode 16+ 与 Metal toolchain；
- Wine 8+ headers/tools；用于 Wine 时为 cross build；
- 64-bit Windows DLL + x86_64 Unixlib 的 `build-win64.txt` 还要求 `x86_64-w64-mingw32-{gcc,g++,ar,strip,windres}`。

本机有 Xcode 27 / Metal toolchain，Meson 1.12.0 也满足 `>= 1.3`；真正缺少的是 LLVM 15、mingw-w64 cross compiler，且现存 CodeWeavers 源树只含一小部分 `dlls/`，没有可传给 DXMT 的完整 Wine build tree、headers 和 `winebuild` 工具。因此阻塞是**LLVM/mingw 工具链 + 完整 Wine 交叉构建输入缺失**，不是可以安全用现成 15.0 二进制改 load command 的问题。

同时，官方 v0.80 源码本身具有版本分支：`DeviceImpl` 在 macOS 14 上限制 `metal_version_` 为 Metal 3.1；只有 macOS 15+ 可升到 Metal 3.2。`setup_metal_version()` 的 3.2 case 明确设置 `air64-apple-macosx15.0.0`。这证明 15.0 不是纯粹的无意 SDK 漂移，但也不能单靠源码文字推断 3.1 路径已在 macOS 14 与本 Wine/runtime 闭包实测成功。

## 未执行的操作与后续门

由于审计时游戏正在运行，未创建/替换 APFS DXMT candidate runtime，也未运行任何 Wine/prefix/D3D 命令。唯一 Wine 查询是直接执行活动 Unix Wine 二进制的 `--version`：exit 0，输出 `wine-11.0`，无 UI、无 prefix。

若未来要继续，先在外置盘隔离准备官方要求的 x86_64 LLVM 15、mingw-w64 和完整且 ABI 对应的 Wine build tree；本机 Meson 已满足版本门。以 `MACOSX_DEPLOYMENT_TARGET=14.0`、`CFLAGS/CXXFLAGS=-arch x86_64 -mmacosx-version-min=14.0` 配置官方 v0.80 cross build。仅在产物通过 x86_64、`minos <=14.0`、install-name/依赖、预期 Unixlib 导出、包 DLL 哈希和无 UI `wine --version` 门后，才能放入全新 APFS clone 槽。之后还必须先解决 GMP/PCRE2/zstd closure，并在真正 macOS 14 冷机上做图形实测，才有产品级兼容性结论。

官方依据：[DXMT v0.80 DEVELOPMENT.md](https://raw.githubusercontent.com/3Shain/dxmt/v0.80/docs/DEVELOPMENT.md)、[DXMT Installation Guide](https://github.com/3Shain/dxmt/wiki/DXMT-Installation-Guide-for-Geeks)。


## RC5 build 13 接续与 macOS 14 测试计划（2026-11-05）

所有者重新明确产品最低目标为 macOS 14；这是实施目标，不是当前已通过的兼容性结论。本轮对实际 RC5 安装 runtime 重新只读扫描：82 个 Mach-O，最高 minos 15.0，唯一超出 14 的模块为 DXMT `lib/dxmt/x86_64-unix/winemetal.so`（SHA 仍为 16e32803…3faf0）。旧审计记录中的三枚 26.0 依赖已由当前 runtime 锁定补丁替换，不应拿旧闭包结果描述当前候选。App/原生 helper 构建的 31 Mach-O 最高 14.0，只覆盖包内第一方与原生辅助模块，不覆盖首次下载到的整个 runtime。optional idv-login 6.3.3 原始可执行入口 minos 11.0；其自解包依赖仍需单独在 14 冷测。

审计时发现 `find` 不遍历作为根参数的 current 符号链接，导致旧命令可能给出“0 Mach-O”假通过。已将输入根解析为真实路径，零文件改为明确失败，新增 symlink-root/empty-root 回归并纳入完整 App 构建。没有修改现有 winemetal.so 的 load command，也没有降低 runtime manifest 的最低版本或哈希验证。

可行修复路线：用官方 v0.80 的准确来源和与当前 Wine 匹配的 headers/tools，在独立目录补齐 x86_64 LLVM 15、mingw/llvm-mingw 和 Wine build tree，以真实 macOS 14 deployment target 重建 DXMT 的 Unixlib 与匹配 Windows DLL；保留源码中的 Metal 3.1/3.2 availability 分支。先完成导出/ABI、install-name、完整依赖和 minos<=14 审计，再建立全新版本槽并同步 hash/catalog/source 材料。不能把只改版本号或 `wine --version` 成功当作完成。当前 PATH 未找到 llvm-config(-15)、mingw gcc、winebuild/winegcc，常用 LLVM15/mingw 安装位置也未发现；完整工具链与 Wine ABI 输入尚未准备，因此此轮没有生成可激活的 macOS14 DXMT runtime。

验收矩阵分两层：

1. 干净 macOS14 VM：原生 App 打开、三语与路径交互、Rosetta 首次流程、runtime/核心/可选组件下载与校验、默认目录首次创建、暂停/取消/续传、全树复验、正式启动到 dwrg.exe 进程。VM Metal 黑屏只按已授权边界记录，不替代图形验收。确认 dyld 没有缺失符号/最低系统错误，不能通过关闭校验或改用户系统证书绕过。
2. 真实 macOS14 GPU：使用同一最终 runtime 做 Metal3.1 着色器编译、公告场景、鼠标/键盘和音频、冷/暖启动与更新重开；至少一台 macOS15+ 验 Metal3.2 分支，确认没有回归。只有两层与签名/hash/来源材料均通过，才能将 README 中的“14 支持未完成”改成支持声明。

当前阻碍是完整图形 runtime 重建与 14 实机，而非 App Info.plist 的 14.0 标记。


## 成本边界复核与本轮停止（2026-11-05）

所有者补充：若只是小范围处理可继续，若需要大量适配则放弃兼容。本轮据此限定为只读核查和两个官方小型发布包审计，没有启动大型编译、修改二进制最低系统或切换日用runtime。此前“工具输入缺失”须纠正为“PATH未暴露”：在既有本地APFS重建归档中找到官方v0.80 clean源码（589adb780354b461645b29999cefaf533594ee99）、LLVM15源码/静态库、llvm-mingw和Wine11 headers/tools；它们没有被修改。Metal Toolchain 27A5194o也已安装，正常访问Xcode注册缓存后 metal --version 成功，先前沙箱内查询失败不代表实际缺工具链。

实际重用门槛：现存LLVM15 libLLVMCore.a抽样对象AbstractCallSite.cpp.o自身minos15.0，不能把该静态对象直接链接成合格14产物。Homebrew官方llvm@15的x86_64 Sonoma瓶装包可作为免重编LLVM的候选：SHA-256 `08430f7b9a8b839fbc65b90f6e2ba5f7969daa8a6f05a6863a39b2af500527c1`，HEAD确认278,783,571 bytes；本轮没有下载或执行它，也没有证明其静态依赖与DXMT构建已适配。故不应把“必须从零重编全部工具链”当定论，但仍不是只重封App能解决。

官方发布包的只读实物结果：

| 版本 | 下载字节与发行SHA-256 | winemetal.so最低系统 | 判断 |
| --- | --- | --- | --- |
| v0.80（当前） | 官方锁定资产，现runtime模块SHA 16e32803…3faf0 | 15.0 | 保留现版本仍需真实重编DXMT |
| v0.74 | 18,990,005；2598981a8b725653773e277470a95dda4253b8a14d36e0dc96dce0e3800f0ceb | 15.0 | 不能直接解决14 |
| v0.61 | 18,905,792；42356902e1d75955f06a593e2ead3a32f95ac8b5c7c9d684c7168308873c4d1b | 14.0 | 只是旧引擎退路，不是当前0.80兼容性证明 |

v0.61包有11个成套文件（一个Unixlib及匹配的64/32位Windows DLL）；Unixlib仍嵌有官方CI机器的绝对winemac.so路径，若采用须正规修正依赖路径、重签、同步整套DLL及hash/来源记录，不能只换一枚.so。降级还放弃0.74/0.80间的同步、timestamp query及兼容性改进，不能未经回归把它当等价替换。官方v0.80及旧v0.61仍属MIT时代；本地LLVM15源码许可是Apache-2.0 WITH LLVM-exception，未来重分发仍须保留准确许可、第三方通知和对应构建来源，不能用许可允许代替兼容性验证。

保留0.80的实际成本至少为：准备合格的14 LLVM输入、DXMT交叉配置及完整编译、审计Unixlib/匹配DLL/依赖、生成独立runtime版本槽与hash/来源材料、14 VM冷测，再由真实14 GPU检验Metal3.1路径并在15+回归。是否还需额外源码/API适配尚未经编译证明，本轮不编造零改动或固定工期。没有可靠证据把它归为“小范围打包”，因此按最新成本边界停止本轮14推进，保留已有15+方案；没有生成14候选可交VM。既有build13仍可接续15+的安装下载验证。原PR历史评估分支原样保留，反馈补丁未触碰。

官方依据：[v0.80构建说明](https://raw.githubusercontent.com/3Shain/dxmt/v0.80/docs/DEVELOPMENT.md)、[v0.80 CI配置](https://raw.githubusercontent.com/3Shain/dxmt/v0.80/.github/workflows/ci.yml)、[Homebrew llvm@15元数据](https://formulae.brew.sh/api/formula/llvm@15.json)、[v0.61 Release](https://github.com/3Shain/dxmt/releases/tag/v0.61)、[v0.74 Release](https://github.com/3Shain/dxmt/releases/tag/v0.74)、[v0.80许可](https://raw.githubusercontent.com/3Shain/dxmt/v0.80/LICENSE)。
