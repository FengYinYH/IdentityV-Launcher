# 游戏语音消息回听出现周期性低幅气泡音：诊断边界（2026-09-24）

## 现象与版本条件

2026-09-24 收到玩家反馈：游戏内**语音消息**用 Mac 内置麦克风录制后，自己点开语音条回听时，长消息有类似气泡的异音；最初粗略描述为约每三秒一次，其他 App 未出现。2026-09-25 风吟进一步回听后修正听感：气泡破裂般的低音量声音叠在语音背景里，语音本身连续、没有被切断；听到的位置约在录音的 1–2 秒、6–7 秒、11–12 秒，事件中心相隔约五秒。这个定位优先于最初的三秒估计，但时点仍是听感近似值。不能将此现象等同于先前切窗时的音频异常。

本轮只读取正在运行的已安装发行版与其既有日志，没有重启游戏、改变音频设备、录制麦克风或替换运行组件。活动游戏加载 CodeWeavers 26.1 / Wine 11 的原装 `winecoreaudio.so`（SHA-256 `64c2ff993e7e2341ef28a4b2fcc0bb23b0fa207ab3bcd89fa2963e8f3d319881`）及发行版 `IdentityVCoreAudio-rebinder-filter.dylib`。运行器记录 `rebinder-filter` 已绑定 Wine 的两处 CoreAudio 属性读取入口，并将输入设备列表缩窄为默认输入。源码中的 `default-input-only.patch` 只是尚未进入该活动 runtime 的隔离候选，不能归因于它。

## 已观察到的证据

- 游戏主日志明确显示 `VoiceNative::StartRecording`，参数为 WAV、单声道、8 kHz、放大系数 1.5；00:00:08 开始录制，00:00:22 结束，00:00:24 开始回听。游戏私有目录里最接近该时刻的约 14.45 秒 WAV 与这次录制时长相符。只做了离线数值检查：这条及随后两条语音文件均没有固定三秒一次的明显 PCM 单样本跳变、连续全零 10 ms 块或削波块。该检查不能识别所有可听的短促失真，也不能证明问题只在回放；未播放或转存语音内容。
- 另一个 `ccmini` 实时语音模块在 22:51:13–22:59:08 的日志每约 15 秒持续报告约 323–324 个捕获帧，且有 95 条 `capture=1345826598 ms` 的异常延迟告警，约每五秒一条。**这不是已确认的语音消息录制路径**，不能用这些计数或告警解释这次三秒破音。
- 运行器日志仅显示启动期设备枚举拦截成功，没有报告采样回调的时间、丢帧或 PCM 不连续。游戏日志里未找到明确的 underrun、overrun、overflow、underflow 或 discontinuity 报告；没有这类字样不代表音频流连续。
- 对照发布所用 CodeWeavers 26.1 源码，`rebinder-filter` 只改 `AudioObjectGetPropertyData{,Size}` 的特定设备枚举调用；Wine 的 `ca_capture_cb`、`capture_resample`、`unix_get_capture_buffer` 及游戏语音 DSP 不经过该拦截逻辑。它可能通过选中的设备间接影响采集，但现有证据不支持把三秒周期直接归因于枚举拦截。Wine 的采集缓冲和重采样路径存在可产生短促失真的一般风险，尚无本机定时证据定位到哪一处。

## 判断与下一步

**根因未确定。** 语音消息确实以 8 kHz 录制，但仅凭该格式和系数 1.5 不能推断周期的来源。此前关于 `capture_resample()` 的解释“转换器短帧时原代码仍发布整段请求量、暴露旧尾部”已被推翻：`AudioConverterFillComplexBuffer` 会回写 `wanted_frames`，原代码调用后使用的已经是实际数量。2026-11-07 的真实离线转换验证见下文。[`capture-resample-produced-frames.patch`](../wineAudioPatch/capture-resample-produced-frames.patch) 额外保留字节数上限与零输出退出；它已在默认跟随模块中，本轮保持其代码，不再将旧理由或 audio1 当成气泡音的新修复。

### 2026-09-24 本地测试候选更新

已将补丁编译为 x86_64 `winecoreaudio.so`，按启动器现有 Developer ID 签名，并加入本地测试版 `1.0.0-rc.1-test.2` 的六项 runtime 补丁清单。新 runtime 是独立版本目录；原 r1 runtime 和全局 `current` 指向均保留。启动器安装后切换用户态 runtime 绑定，再由风吟进行游戏内语音消息录制与回听。此次构建、签名、哈希和 runtime 清单校验通过，只说明构件可被本地测试版识别；**尚未验证游戏启动、麦克风授权、短帧分支或实际语音质量**。测试前后都不能把破音是否消失当成根因证明；还需对照同一条语音文件的游戏回听和独立播放器，区分录制文件与游戏播放/解码路径。

如果系统再次显示麦克风授权提示，由用户按预期授权。不得自动开始录音或在用户游玩时切换活动音频组件。

### 2026-09-25 test.2 实机回听

风吟反馈：安装并选中 `r1-emoji2-audio1` 后，语音消息回听中的气泡音仍存在；这说明本次 CoreAudio 重采样候选**没有消除可感知问题**，但单次试听不能确定它完全无效或根因在别处。游戏目录中最新的一条 12.67 秒、单声道 8 kHz PCM 语音 WAV 与测试时段相符，可作为本地样本继续分析；未复制或外传原始语音。初步离线数值检查未见削波；较大的相邻采样跳变在约 6.0 秒及 11.8–11.9 秒，和风吟给出的两个听感区间大致接近，但幅度跳变本身不等于听到的低音量气泡音，也不能说明语音连续性有问题。下一步应对照原 WAV 在游戏与独立播放器的听感，并把异音时点与短时频谱/底噪变化对齐。

私人原始日志保留在本机原路径；本页只保存可公开的聚合证据，不含游戏账号或原始声音。

## 2026-11-07 RC6 定向复核

### 时间线、播放路径与时钟边界

气泡音在9月23–25日已有记录，早于10月4日原生双向默认设备跟随实现和10月5日切换验收，不能解释成这次补丁首次引入的回归。这里须区分更早的默认输入枚举拦截：它已在9月现场使用，其设备选择的间接影响不能仅靠这条时间线排除，但现有证据也未把它与周期回听气泡对应。早期研究的9月28日补充还记录了用户对照：**同一 WAV 在系统播放器正常，游戏回听有气泡音**。这使游戏的播放、解码或 DSP 路径成为更有依据的排查方向，也不等于已经找到具体函数。原12.67秒样本目前缺失，已在游戏、prefix、既有报告和 local 的相关位置窄搜；本轮没有新录制或设备操作，不重复全盘寻找样本。

设备时钟协调、缓冲、热插拔和恢复都是有效的音频工程关注点，但不能单凭这些要求推定本例根因。精确 CW 源码用设备格式的采样率配置 AudioConverter，采集端的 `cap_bufsize_frames` 由流时长乘设备采样率得到；客户端环按 Windows 格式的采样率分配，`resamp_period_frames` 按两种采样率换算。默认设备变化时重新建立 unit/converter，并在没有客户端持有 buffer 时清空旧 backlog；未发现把旧设备采样率直接沿用到新设备的证据。已有逻辑不测独立设备间时钟漂移，也没有自适应漂移补偿；尚无现场计数支持把约五秒听感归于时钟积差。独立音频中心仍是另一个项目，不是本轮修复前置。

### 已确证的客户端环形读偏移缺陷

精确 CodeWeavers 26.1 原源码 SHA-256 为 `635347dcfc86800ed64737c6487a808836240e7846c6af699493e7a683d3f42c`；现行默认跟随源码为 `ccd1db550dd16471e1f6df203e880928d1474aa82a42a9bc994d083f0baa3153`。两者在 `capture_resample()` overflow 后都只做 `lcl_offs_frames += distance`，没有取模。例如容量800、旧读位置760、已持有780、写位置740，再产生80帧，写位置变20，旧读位置加圆环距离60后变820。后续 GetBuffer 的 `capacity-offset` 发生无符号下溢，返回越界指针。

[`capture-ring-offset-normalization.patch`](../wineAudioPatch/capture-ring-offset-normalization.patch) 只在该分支增加取模，保留既有“丢弃最老数据、保留最新整环”策略。候选源码 SHA-256 为 `548fd223c54e5bd30dd23d5ace4975668d19ac2a195be4d56f1ef6ce7ed0e79c`。这是一项独立内存边界修复，尚未证明游戏实际触发，更未证明它产生所述气泡音。

[`testCaptureRingOffsets.py`](../wineAudioPatch/testCaptureRingOffsets.py) 从上述完整固定摘要源码抽取真实 callback、resample、GetBuffer、ReleaseBuffer 和辅助函数，以合成 PCM、mock converter/render 驱动，使用 AddressSanitizer 与 UndefinedBehaviorSanitizer：

| 检查 | 原CW / 当前默认跟随 | 仅加取模候选 |
| --- | --- | --- |
| 8k/48k mono、4种容量、101个读位置、4种占用，共3232例 | 各169例真实GetBuffer非法指针 | 0例非法指针，样本顺序和Get/Release通过 |
| 真实返回指针的主动读取 | ASan heap-buffer-overflow | 对应正常矩阵通过 |
| 跨环包读取及Release归一化 | 合法位置验证通过 | 通过 |
| 客户端持有包期间callback、重复Get、错误Release、Release(0)、重新Get、完整Release、空缓冲 | 通过 | 通过 |

反证必须保留：`lcl_offs_frames == N` 虽不规范，GetBuffer 的零长度首段随后可安全从环首复制到临时包；只有 `> N` 才是本次非法指针。最初把 `== N` 也计作非法的判据已撤回，169是实际返回非法地址的数量。早期 oversized callback probe 曾被 LLVM 当死写删除；增加 memory-observable barrier 后才得到真实 ASan 失败，不能用此前空 probe 当安全证据。

### 另一个未修边界：callback 超整环

原CW、当前模块和取模候选的 `ca_wrap_buffer()` 都只支持一次环尾拆分，`nframes > cap_bufsize_frames` 时可能写出环外。本轮负例采用48k设备格式、1440帧环（30ms，符合默认shared流的合法时长），注入4096帧合成callback，三者均真实ASan溢出；**4096是测试输入，不是本机设备实测值**，该负例不计入candidatePass。

源码事实：mmdevapi 默认周期10ms、最小5ms；shared时长至少3周期，exclusive非event至少8周期。创建与设备重建按 `duration × deviceRate` 分配采集环；均未查询或设置 `kAudioUnitProperty_MaximumFramesPerSlice`，也未核验它与环容量的关系。SDK将该属性定义为单次render允许的最大帧数，涉及倍率时应拆分输入pull。因本轮不创建真实unit或查询设备，无法证明当前硬件回调会超过环，也无法从现源码证明永远小于环。48k→8k换算不为原始设备环增加额外容量；重建时重新计算容量，但仍缺上述关系校验。

若后续确需修复，有两个窄选项：一是创建/重建时按可信最大slice预分配环与scratch，并处理该上限变化；可避免callback中新增分配，但会影响容量、延迟与生命周期。二是对超环回调先render到足够的scratch，仅按圆环语义保留最新N帧并同步更新读写偏移；需验证丢帧计数、长回调和client-held时序。直接跳过超长callback虽防越界却丢整块声音，不宜静默当作音质修复；多次AudioUnitRender拆分也涉及时间戳/输入pull契约。取模候选未扩大到这些改动，Root可据实际slice证据选择后续方案。

### 真实 AudioConverter 与候选构件

[`audio_converter_packet_counts.c`](../wineAudioPatch/repro/audio_converter_packet_counts.c) 使用系统真实 `AudioConverterNew/FillComplexBuffer`，只输入内存合成PCM，不创建AudioUnit或查询设备。结果：8k→8k请求80实际17/34字节；48k→8k末包请求80实际21/42字节；8k→48k末包请求240实际102/204字节；结束时实际0/0字节。它直接推翻旧“wanted_frames总是请求量”的解释，不证明游戏里的converter曾返回短帧或原气泡音位置。

[`buildCaptureRingX64.command`](../wineAudioPatch/buildCaptureRingX64.command) 从固定摘要CW归档应用原有三项补丁，再应用最小取模补丁；只构建 `dlls/winecoreaudio.drv/winecoreaudio.so`，保留默认跟随和原produced-frames代码。构建通过，导出符号与动态依赖列表和当前签名模块 `9588fcdd5b262e85e9255c647b6a5a43b077553b6d8531d5c7ab8d6eb27186d8` 完全一致；thin x86_64、install name `@rpath/winecoreaudio.so`、最低系统10.15、loader rpath检查通过。该模块目标不代表完整产品支持macOS14。

| 候选阶段 | SHA-256 |
| --- | --- |
| 原始构建 | `814c145e450c58f081b724c5e050e27ff4d11e2fdf53c11b18367503891d4755` |
| `strip -S -x` 后、签名前 | `f2c2597085d0b6e02ae67b19b8a91d4bbf56e3fc94e072f4b7956fb3be41b4c3` |
| 独立ad-hoc hardened-runtime签名副本 | `d62f650b68911e30ed3549f1f34e7fbd2f86d90fbe749aebde3081de9cc678eb` |

签名严格验证通过；ad-hoc副本仅供本机审查，发行Developer ID签名会改变摘要，须由最终集成重签后锁定。原构建、源码、ASan失败和成功证据均保留在独立私有档案；复建命令和工具要求见[复现说明](../wineAudioPatch/repro/README.md)。本轮没有替换当前runtime、prefix、manifest或安装物，没有启动游戏/GUI/录音，未改系统设备或权限，没有commit/push。实际游戏质量、当前硬件callback上限、最终runtime加载与发行签名由集成阶段单独验收；RC6不能据此宣称气泡音已消除。本轮保留该最小候选及完整复建证据，未用它替换默认模块。

### 接续验证对象

下一次有可复现的问题语音时，优先复用同一原文件分别在游戏与系统播放器回听，并记录多个异音时点，不以重新录麦克风或切换设备作为默认前置。若文件本身正常而仅游戏回听异常，限定到8k播放流统计callback帧数、队列/填充量、丢帧/不连续计数及主机时间与采样率；只保存有限聚合计数，不保存PCM、账号或语音内容。将听感时点与播放队列/时钟突变对应，才能判断缓冲对齐、解码/DSP或设备切换路径，不能拿本次采集越界候选替代这一步。
