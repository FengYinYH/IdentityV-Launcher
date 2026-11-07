# CoreAudio 默认设备属性读取基准

此基准测量 `AudioObjectGetPropertyData` 查询 macOS 系统对象的默认输入或输出设备属性时，本进程和采样线程消耗的 CPU 时间、单次调用耗时及定时调度迟到情况。它用于评估 Wine 已有的 100 ms 音频 timer 中默认设备属性读取成本；基准自身用 `mach_wait_until` 按目标节拍等待，不代表产品新增了 timer 或线程。

程序只查询 `kAudioHardwarePropertyDefaultInputDevice` 和 `kAudioHardwarePropertyDefaultOutputDevice`。它不打开麦克风、AudioUnit 或音频流，不请求麦克风权限，不读音频样本，不枚举或输出设备名称，也不更改系统设备。

默认运行包含 30 个 15 秒样本，重复三轮并配对空等待基线：10 次/秒分别测输出属性和输入属性；20、40、80 次/秒则每个节拍只查询一个属性，在输入与输出之间交替，以模拟多条现有流的合计读取频率。每个查询样本都有同频率的基线样本，基线保留 `mach_wait_until` 节拍而不调用 CoreAudio。源码记录进程和当前线程的 user/system CPU 时间、墙钟时间、调用耗时分位数、调度迟到、状态码和测试前后的 1 分钟系统负载。默认一次会写出 7,200 条属性调用记录和 7,200 条配对基线节拍记录。

在 macOS 上从此目录编译并运行，两个 CSV 路径由操作者指定：

```sh
clang -std=c11 -O2 -Wall -Wextra -Werror audio_property_benchmark.c \
  -framework CoreAudio -framework IOKit -o audio_property_benchmark
./audio_property_benchmark summary.csv calls.csv
```

比较样本时一并记录 Mac 型号、macOS 版本、电源状态及同时运行的负载。CPU 时间与墙钟时间表达不同信息：基准大部分时间在等待，CPU 占用不能从 15 秒墙钟时长直接推断。调用最大值可能包含线程被系统暂时调度出去的时间；结合中位数、p95、定时迟到和负载观察，不能把单次最大值都解释为 CoreAudio 自身执行时间。

这些数据不测电量、功耗、游戏帧率或玩家听感，也不验证真实设备切换与游戏内音频行为。实际 Wine 改动复用现有 timer；本基准的等待用于隔离读取成本，不能单独作为更换 listener/timer 机制的理由。

## 捕获环与实际转换器的离线复现

背景、固定源码摘要、错误判据、成功与失败结果见[气泡音专题](../../docs/audioCapturePeriodicArtifact20260924.md#2026-11-07-rc6-定向复核)。下列命令从仓库根执行；大写路径变量由调用者设置，输出必须是新的目录，不应指向runtime或prefix。

```sh
python3 wineAudioPatch/testCaptureRingOffsets.py "$CURRENT_COREAUDIO" "$NEW_RING_OUTPUT" \
  --upstream "$ORIGINAL_COREAUDIO"
```

输入必须分别匹配现行默认跟随 `ccd1db…3153` 与原CW `635347…f42c` 全文摘要，脚本会核验。它生成最小取模candidate，分别提取真实C函数并以ASan/UBSan编译运行。converter和AudioUnitRender为合成PCM fixture；没有真实设备。每种源码3232例；原版/现版各169例非法GetBuffer地址，主动读取触发ASan；候选0例且样本顺序、持有包、Release(0)等边界通过。独立超环callback负例三种源码都应ASan失败，脚本将该失败记录成已知未修缺陷，不能当作整体音频安全通过。

真实转换器的离线复现另行执行：

```sh
mkdir "$NEW_CONVERTER_OUTPUT"
xcrun clang -std=c11 -Wall -Wextra -Werror -O1 \
  wineAudioPatch/repro/audio_converter_packet_counts.c -framework AudioToolbox \
  -o "$NEW_CONVERTER_OUTPUT/converter-counts"
"$NEW_CONVERTER_OUTPUT/converter-counts" > "$NEW_CONVERTER_OUTPUT/result.txt"
```

此程序创建内存PCM AudioConverter，无AudioUnit或设备查询。它断言实际帧数不超过请求，字节数与实际帧数一致，且确有短帧；同采样率17帧包也核对逐样本数据。`AudioConverterFillComplexBuffer` 的packet参数是输入输出变量，原源码的wanted_frames已经会被回写，不能继续沿用“按完整请求发布短帧”的旧解释。

## 仅取模修复的x86_64模块

先设置源码归档、现存llvm-mingw/Bison工具、当前基线模块和已确认外部卷身份，使用全新构建leaf：

```sh
export CROSSOVER_SOURCE_ARCHIVE LLVM_MINGW_ROOT BISON ACTIVE_AUDIO_MODULE
export IDV_WINE_AUDIO_VOLUME IDV_WINE_AUDIO_VOLUME_UUID IDV_WINE_AUDIO_BUILD_ROOT
zsh wineAudioPatch/buildCaptureRingX64.command
```

归档SHA-256固定为 `e4ec87d5821a009dd1f1d2e36ffe2e24b8fcbae9516375ea42f95a16928ab8fa`；llvm-mingw需带可执行的 `bin/x86_64-w64-mingw32-gcc`，本次使用20251216 ucrt macOS universal与Bison3.8.2。基线模块固定为专题中的 `9588fc…186d8`。builder验证挂载点/UUID和新目录后，提取 `sources/wine`、核对原源码，依次应用default-input-only、capture-resample-produced-frames、default-device-following、capture-ring-offset-normalization，并复制默认跟随状态头；调用x86_64 configure与仅模块make，不重建整套Wine发行。完整configure参数、编译日志、模块摘要、exports、dependencies与load commands随输出保留，minOS固定10.15。该脚本不签名或安装。

后续若仅制作本机审查副本，在新的私有目录保留raw后操作副本：

```sh
cp "$IDV_WINE_AUDIO_BUILD_ROOT/source/dlls/winecoreaudio.drv/winecoreaudio.so" "$NEW_REVIEW/winecoreaudio.raw.so"
cp "$NEW_REVIEW/winecoreaudio.raw.so" "$NEW_REVIEW/winecoreaudio.stripped.so"
strip -S -x "$NEW_REVIEW/winecoreaudio.stripped.so"
cp "$NEW_REVIEW/winecoreaudio.stripped.so" "$NEW_REVIEW/winecoreaudio.adhoc.so"
codesign --force --sign - --identifier winecoreaudio --options runtime --timestamp=none "$NEW_REVIEW/winecoreaudio.adhoc.so"
codesign --verify --strict --verbose=4 "$NEW_REVIEW/winecoreaudio.adhoc.so"
shasum -a 256 "$NEW_REVIEW/"*.so
```

`NEW_REVIEW`须预先新建并确认为空。ad-hoc签名不调用Developer ID私钥，不提供发行身份或最终runtime加载验收。Root最终签名/集成时须重新计算摘要和核验完整runtime；本阶段不连接manifest或安装入口。重建后的raw摘要可能受构建路径/工具版本/调试信息影响，应同时核对固定源码、导出、依赖、架构和部署目标，不能仅凭不相同的raw摘要判定源码不同。
