# CoreAudio 默认输入与输出跟随候选

## 目标和证据范围

第五人格使用 Wine CoreAudio 时，播放和采集流分别跟随 macOS 当前默认输出、默认输入。设备选择继续由 macOS “系统设置 → 声音”负责；Wine 不向游戏枚举所有硬件，也不增加设备选择界面。此版本已作为本机产品默认 runtime 安装并绑定；audio1 保留为显式回退。真实设备切换和游戏语音验收尚未进行，本机默认状态不代表公开发行。

代码以 CodeWeavers 26.1 源码包为基线：归档 SHA-256 `e4ec87d5821a009dd1f1d2e36ffe2e24b8fcbae9516375ea42f95a16928ab8fa`，未修改 `coreaudio.c` SHA-256 `635347dcfc86800ed64737c6487a808836240e7846c6af699493e7a683d3f42c`。补丁顺序是 `default-input-only.patch`、`capture-resample-produced-frames.patch`、`default-device-following.patch`；最终 C 文件 SHA-256 `ccd1db550dd16471e1f6df203e880928d1474aa82a42a9bc994d083f0baa3153`。新补丁复用既有输入枚举修复和录音转换帧数修复，没有替换它们。

源码已有 `kAudioHardwarePropertyDefaultOutputDevice` / `kAudioHardwarePropertyDefaultInputDevice` 查询和 HALOutput 当前设备绑定。Wine 每个成功 Start 都会创建该流已有的控制 timer；新逻辑 piggyback 在这个线程上，每 100ms 只轮询该流对应的一个默认设备属性，约为每个 started stream 每秒 10 次属性读取。Start 过的 timer 会一直运行到 stream Release；单独 Stop 并不会结束它，所以未 Release 的 stopped stream 仍计入轮询量，多流成本随仍保留的 started stream 数量累加。此实现没有新增线程；CPU/功耗影响没有实测。

本轮不用 CoreAudio listener，是因为 listener 会引入进程/driver unload 时注销、重复注册、跨流 callback context 生命周期，以及事件与 stream teardown/重建竞争的同步工作。复用已有 per-stream timer 以少量可估算的属性轮询换取更简单的生命周期；若未来实测表明轮询开销不可接受，再在具备明确 unload 与引用计数协议后考虑 listener。

输入继续使用既有 `ca_setup_audiounit` 转换器，根据新设备采样率重建采集容量。

## 路由切换与状态恢复

检测到默认设备变化后，控制线程先在流锁内将设备标记为不可用。CoreAudio 回调随后只输出静音或丢弃输入；Stop、Dispose、重建和 Start 均在锁外执行，避免持 callback 锁等待回调排空。若 Windows 客户端仍持有 Capture buffer，重建会推迟到 Release，避免释放仍被借出的缓冲区。

只有初始化和启动成功、采集容量可安全分配，并且再次查询确认默认设备仍是目标设备时，控制线程才发布新 AU/converter。若初始化中又发生快速切换，本候选会丢弃刚建好的旧目标并在后续轮询重试。切换失败会 Stop/Dispose 临时 AU，释放 converter 和临时采集容量；活动流保留 Windows 格式、播放状态、音量设置与逻辑位置，并每隔约 500ms 重试。启动阶段也在 AudioUnit Start 前准备好回调可访问的 local/capture buffers；创建、容量分配或初始化失败都通过同一失败清理路径释放资源。

恢复时清除旧 render/capture 积压，避免路由恢复后突然播放旧音频。切换期间已交给 Windows 的 render 帧仍增加逻辑 written-frame 计数，但数据被丢弃；Capture 对不可用设备报告空缓冲，已借出的 capture buffer 先正常 Release，之后清除旧数据。该策略保持流的 Windows session 和单调位置语义，但真实应用对设备失效的感知和体验仍需实机验证。

音量缓存同时为 render 和 capture 分配，因为 mmdevapi 在两种 flow 的建流路径都会调用 set-stream-volumes。重建成功时重新应用缓存。端点查询始终只返回该 flow 当前默认设备；读取失败时 fail-closed，不猜测替代设备。

## 验证和候选边界

`default-device-following-state-test.c` 是不访问 CoreAudio 的合成测试，覆盖路由状态、快速切换候选确认、停止保护、重试间隔、位置与积压语义，以及 capture 容量分配失败和 AudioUnit 初始化失败时不发布候选并释放已建资源。xcrun clang 以 `-Wall -Wextra -Werror` 构建并运行通过。它验证纯策略和失败状态模型，不代替系统 CoreAudio 的运行期故障注入。

`buildDefaultDeviceFollowingX64.command` 从校验过哈希的源码归档重放上述三份补丁，要求调用者显式提供源码归档、llvm-mingw、Bison、audio1 基线模块、外部卷挂载点及 UUID，以及该卷内一个新的构建目录。脚本核对归档/源码/基线哈希、x86_64 Mach-O、install name、10.15 minimum OS、导出符号和动态依赖；不回落到内置磁盘，不签名、不安装、不启动 Wine，也不打开麦克风或音频设备。

构建环境通过 `CROSSOVER_SOURCE_ARCHIVE`、`LLVM_MINGW_ROOT`、`BISON`、`ACTIVE_AUDIO_MODULE`、`IDV_WINE_AUDIO_VOLUME`、`IDV_WINE_AUDIO_VOLUME_UUID` 和 `IDV_WINE_AUDIO_BUILD_ROOT` 显式传入；卷挂载点和预期 UUID 必须由调用者确认，脚本只在新建的构建目录工作。runtime clone/stage 使用项目维护者工具，参数形态如下，所有占位符都必须替换成已核验的本机输入，目标目录必须尚不存在：

```sh
wineAudioPatch/stageDefaultDeviceRuntime.command \
  --source-tree /absolute/path/to/verified-audio1-runtime \
  --source-module /absolute/path/to/unsigned-stripped-winecoreaudio.so \
  --module /absolute/path/to/developer-id-signed-winecoreaudio.so \
  --bootstrap /absolute/path/to/runtime-bootstrap \
  --destination /absolute/path/to/external-volume/new-isolated-candidate \
  --volume-mount /absolute/path/to/external-volume \
  --volume-uuid EXPECTED_DISK_UUID
```

Stage 工具用 audio1 快照 manifest 验证源树、用当前产品 manifest 校验已剥除 DWARF 的 unsigned source SHA 与 Developer ID signed module SHA，再把新 manifest/catalog 放入新目录并重跑全树校验。目的地必须位于调用者给定且 UUID 匹配的外部卷；目录已存在时拒绝覆盖。历史 Bison 工具路径故障：随工具链归档的 Bison 是 GNU 3.8.2，版本足够；资源目录需通过 `BISON_PKGDATADIR` 指向随附的 `share/bison`。Wine configure 将 `$BISON` 未加引号展开，含空格路径会被拆开；失败日志显示可执行路径截断到挂载目录第一段。构建脚本在外部构建目录内为其创建无空格链接并设置数据目录。前两次 configure 失败证实了路径拆词原因，随后完整 x86_64 构建成功。

对照的 audio1 模块 SHA-256 为 `90419c1a4009407b28b353614b883ef3d1531e8b852416fe0eaf704c90b6fce0`。原始新构建为 x86_64，SHA-256 `9591a575e73dd2c1df2b7f6a1937d3a472c9b160455d7f43406f61d28f089c34`。其副本用 `strip -S` 移除 DWARF 后，unsigned source SHA-256 为 `996c8223a3d3b2b6b371062b9f8c121362556cb0222215dbf7ac1fdaa8455160`；审计确认本机用户名、工作区和构建卷路径标记及 DWARF 路径均已清除，导出符号、install name 和 11 个实际动态依赖仍与 audio1 完全相同。随后以 `Developer ID Application: Qingxiong Yang (VNTCB2984V)` hardened runtime + timestamp 签名，最终 SHA-256 `9588fcdd5b262e85e9255c647b6a5a43b077553b6d8531d5c7ab8d6eb27186d8`。本机新 immutable runtime clone 与正式部署树均通过 `verify-tree`；新 engine 已设为本机默认，audio1 是明确回退。未运行游戏/Wine，也没有真实设备切换、录音、播放或语音服务回归。静态 ABI/minOS 比较不能证明音频表现、路由切换时延或语音服务兼容。

## 尚未证实

- 100ms 是轮询间隔，不是切换完成时长。允许短暂约 1–2 秒静音是产品容忍目标，本轮没有通过真实设备测出该时长。
- 未测试蓝牙、USB、HDMI、采样率/声道配置变化、睡眠唤醒、游戏语音录制或播放；没有访问麦克风、触发 TCC 或运行活动游戏。
- 新候选是否消除现场的旧音频积压/持续失声，需要后续在隔离 runtime 中按设备切换做回归。

## 回退

不通过后续实机验收时，将 runtime binding 切回 immutable audio1 版本即可；两版本分别保留，不能原地覆盖已签名 runtime。新版本源文件、manifest、catalog 和签名产物摘要彼此锁定；修改音频模块需创建新版本并重做签名与完整验证。
