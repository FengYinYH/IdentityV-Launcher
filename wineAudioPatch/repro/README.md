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
