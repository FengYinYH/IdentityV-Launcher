# CoreAudio 默认输入与输出跟随候选

## 目标和证据范围

第五人格使用 Wine CoreAudio 时，播放和采集流分别跟随 macOS 当前默认输出、默认输入。设备选择继续由 macOS “系统设置 → 声音”负责；Wine 不向游戏枚举所有硬件，也不增加设备选择界面。本说明记录一个可重建的隔离工程候选，不表示它已经安装或经过真实游戏验收。

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
  --module /absolute/path/to/winecoreaudio.so \
  --bootstrap /absolute/path/to/runtime-bootstrap \
  --destination /absolute/path/to/new-isolated-candidate
```

已知工具路径问题：随工具链归档的 Bison 是 GNU 3.8.2，版本足够；它的资源目录需通过 `BISON_PKGDATADIR` 指向随附的 `share/bison`。此外 Wine configure 将 `$BISON` 未加引号展开，含空格的工具路径会被拆开；失败日志显示 shell 把可执行路径截断到挂载目录第一段。构建脚本在外部构建目录内为该二进制创建无空格链接并设置数据目录。前两次 configure 失败明确证实了路径拆词原因，随后完整 x86_64 构建成功。

对照的 audio1 隔离候选 SHA-256 为 `90419c1a4009407b28b353614b883ef3d1531e8b852416fe0eaf704c90b6fce0`。最终未签名 x86_64 模块 SHA-256 为 `9591a575e73dd2c1df2b7f6a1937d3a472c9b160455d7f43406f61d28f089c34`，install name `@rpath/winecoreaudio.so`，minimum OS `10.15`；导出符号表、install name 和 11 个实际动态依赖与该 audio1 候选逐项相同。原未签名模块保留为复现件。最终 SPDX 标注源码已完成独立 runtime clone、ad-hoc 本地签名、manifest/catalog 派生和全树校验；staged module SHA-256 为 `7da0e02f391e25234d7a4a5ebb62aaca00d6aa220d9c1b843f6f20a2fdabd57b`。此候选没有启动 Wine 或安装到活动 runtime。公开发布前仍须在副本上清理或审计调试符号里的本机路径，再按发行身份签名并重算哈希。静态 ABI/minOS 比较不能证明音频表现、路由切换时延或语音服务兼容。

## 尚未证实

- 100ms 是轮询间隔，不是切换完成时长。允许短暂约 1–2 秒静音是产品容忍目标，本轮没有通过真实设备测出该时长。
- 未测试蓝牙、USB、HDMI、采样率/声道配置变化、睡眠唤醒、游戏语音录制或播放；没有访问麦克风、触发 TCC 或运行活动游戏。
- 新候选是否消除现场的旧音频积压/持续失声，需要后续在隔离 runtime 中按设备切换做回归。

## 回退

新候选独立构建和 staging，不覆盖已安装 runtime。验收不通过时继续选择之前的 immutable runtime/audio1 模块即可；不要把该候选直接复制进已签名 runtime。最终 runtime 目录和激活/回滚由 launcher runtime 管理逻辑维护。
