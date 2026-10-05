# 启动器界面语言

RC2 玩家启动器支持简体中文、繁体中文、英文；改变启动器文案和下次启动的 macOS 游戏宿主名称，不改游戏内容语言或游戏数据。

语言菜单把选择保存到标准偏好键 `com.fengyin.identityv.launcher.ui-language`。没有值或遇到未知值时使用 `system`，让升级保持可预测的跟随系统默认。`LauncherLanguage` 集中管理键名、映射与系统语言解析，以后移入设置层只需迁移这一项，不与某个游戏产品状态耦合。

跟随系统时，中文标识包含繁体脚本或 TW/HK/MO 地区就选繁中，其他中文选简中，其他系统语言使用英文。手动菜单选择立即更新 SwiftUI locale，重开继续保留。构建把三份 `.lproj` 复制进签名 App；`CFBundleLocalizations` 同时向 macOS声明支持的语言。

## 文案维护边界

现有中文文案作为查表键，静态 SwiftUI 标签与可达的反馈页直接使用资源。`LauncherLanguage.localizedMessage` 处理精确匹配和经过审阅的常见进度、安装、重启、授权及反馈格式模板；产品名/动作等已知参数先独立查译名再格式化。未匹配的错误细节保留原文，使诊断证据不会被改写。新增动态文案应增加明确的格式键与自检，不依赖模糊的任意字符串自动翻译。少见的未登记动态提示和外部 helper 输出仍显示原语言。

卷路径启动保护要求在说明安装前不读取 `Bundle.main`；初版本地化查 `.lproj` 会违背这一保护。因此两条启动提示刻意保留代码内翻译，自检要求与资源译文一致。这是防止提前读取外置磁盘映像的限定例外，不用于一般界面。

## 验证与剩余边界

`launcherLocalizationResourcesSelfTest.py` 检查三份表的212个键一致、启动器/反馈页/保留工具视图的静态中文字串均有资源、必需动态模板及麦克风授权提示存在、支持语言列表与文件夹一致。`LauncherLanguageSelfTest.swift` 验证简繁解析（含TW/HK/MO）、其他语言回退、空/非法偏好回退、持久选择、动态进度/动作、错误码提示和邮件客户端fallback。完整构建在编译App前运行两项检查。

实际macOS界面检查补充了纯查表测试的边界：sheet可拥有独立窗口环境，因此安装提示与反馈sheet显式接收当前locale；运行时String占位符须保留为`LocalizedStringKey`，插值版本标签须用完整格式键。更新提示也必须翻译完整消息，不能只匹配前半句。回归检查纳入这些契约；最终安装仍核对实际菜单、弹窗与布局，不能仅凭资源键集合推定SwiftUI呈现正确。

这些检查不替代英文长标签的视觉适配或每个少见运行提示的实际验收；后续增加文案时应按上述统一入口维护。

## 游戏宿主菜单名称与缓存时序

游戏宿主名称在下次启动时采用启动器已解析的语言：简中和繁中为“第五人格”，英文为“Identity V”。ProductManager 显式读取启动器偏好域，复用 `LauncherLanguage` 的同一解析规则，再把受限名称传给内嵌运行器。名称不由国服/国际服推断；游戏内容语言不受影响。

CodeWeavers 26.1 的 `loader/main.c` 在 `main()` 中读取并清除 `WINEPRELOADERAPPNAME`，通过 `vm_protect` 改写 Mach-O 的 `__TEXT,__info_plist`。最初的实现仅设置这个变量，静态 child 合约通过，但实际游戏菜单仍是“CrossOver-Hosted Application”。锁定 x86_64 loader 的 XML 匹配与调用顺序均核对正确；不能凭签名属性把失败归因于 Hardened Runtime 或重执行。

真实签名 loader 的无 GUI `--version` 对照给出关键反证：退出时嵌入的 `CFBundleName` 已是“第五人格”，Foundation 缓存仍为旧名。注入的原生辅助模块链接 AppKit，框架在 Wine 的 `main()` 之前加载；改写映像不等于更新框架的进程内字典。因此现有辅助模块在游戏创建 `NSApplication` 前同步 CFBundle 名称/显示名称和 NSProcessInfo 进程名，保留原始 bundle ID、签名身份和上游运行包字节。只接受上述两枚名称，且仅限包含 `dwrg.exe` 参数的受管游戏进程，不给安装/配置工具改名。

`wineKeyboardPatch/gameDisplayNameSelfTest.command` 编译实际生产辅助模块的适配函数，并通过 `open -g -n` 启动无窗口、禁止激活的 x86_64 probe；外部进程查询 `NSRunningApplication.localizedName`，分别要求简中/繁中共用名和英文名正确。它不打开音频流、不更改设备、不操作游戏。这比字符串/环境变量检查多验证了 AppKit/LaunchServices 的实际名称，但真实 Wine 游戏菜单仍需在最终 App 的下一次游戏启动确认。升级 Wine、框架或系统版本时应保留这层回归，不能只检查可执行映像中的 XML。
