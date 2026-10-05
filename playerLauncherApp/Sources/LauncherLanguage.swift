import Foundation

/// The launcher owns this small preference because language belongs to the
/// launcher UI, not to a particular game product or the host's game data.
/// Keeping the key and migration point here lets a future settings store move
/// the value without changing the UI's language resolution rules.
enum LauncherLanguage: String, CaseIterable, Identifiable {
    case system
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case english = "en"

    static let preferenceKey = "com.fengyin.identityv.launcher.ui-language"

    var id: String { rawValue }

    static var current: LauncherLanguage {
        configured(from: .standard)
    }

    static func resolve(rawValue: String?) -> LauncherLanguage {
        guard let rawValue, let language = LauncherLanguage(rawValue: rawValue) else { return .system }
        return language
    }

    static func configured(from defaults: UserDefaults) -> LauncherLanguage {
        resolve(rawValue: defaults.string(forKey: preferenceKey))
    }

    var locale: Locale {
        switch self {
        case .system: Self.systemLocale
        case .simplifiedChinese: Locale(identifier: "zh-Hans")
        case .traditionalChinese: Locale(identifier: "zh-Hant")
        case .english: Locale(identifier: "en")
        }
    }

    /// Resolved at the next game launch. This labels the macOS host UI only;
    /// the game's own language and product region remain independent.
    var gameDisplayName: String {
        locale.identifier == "en" ? "Identity V" : "第五人格"
    }

    var menuTitle: String {
        switch self {
        case .system: localized("跟随系统")
        case .simplifiedChinese: "简体中文"
        case .traditionalChinese: "繁體中文"
        case .english: "English"
        }
    }

    /// Picker labels describe the launcher UI choice, so the system-following
    /// option must use the selected UI language rather than the host OS locale.
    func menuTitle(in interfaceLanguage: LauncherLanguage, lookup: ((String) -> String)? = nil) -> String {
        guard self == .system else { return menuTitle }
        let lookup = lookup ?? { interfaceLanguage.localized($0) }
        return lookup("跟随系统")
    }

    func localized(_ key: String) -> String {
        let languageCode: String
        switch self {
        case .system:
            languageCode = Self.systemLocale.identifier
        case .simplifiedChinese, .traditionalChinese, .english:
            languageCode = rawValue
        }
        guard let resourceURL = Bundle.main.url(forResource: languageCode, withExtension: "lproj"),
              let localizationBundle = Bundle(url: resourceURL) else { return key }
        return localizationBundle.localizedString(forKey: key, value: key, table: "Localizable")
    }

    /// The mounted-volume guard runs before inspecting Bundle.main. These two
    /// bootstrap strings deliberately live in code: looking up .lproj here
    /// would read the volume that the guard is protecting against.
    var launchLocationCopy: (title: String, message: String) {
        switch locale.identifier {
        case "zh-Hans":
            return ("请先把第五人格启动器拖到应用程序文件夹", "请从磁盘映像中拖到“应用程序”后，再打开启动器。")
        case "zh-Hant":
            return ("請先將第五人格啟動器拖到應用程式檔案夾", "請先從磁碟映像拖到「應用程式」，再開啟啟動器。")
        default:
            return ("Move Identity V Launcher to Applications First", "Drag the app from the disk image to Applications, then open it.")
        }
    }

    /// Runtime messages are ordinary Strings produced by the model rather
    /// than SwiftUI localization keys. Translate exact catalog entries first,
    /// then a small set of stable, high-frequency message shapes. Unrecognized
    /// helper and diagnostic text stays verbatim so its evidence is preserved.
    func localizedMessage(_ source: String, lookup: ((String) -> String)? = nil) -> String {
        let lookup = lookup ?? localized
        let exact = lookup(source)
        if exact != source { return exact }

        let templates: [(String, String)] = [
            ("^正在安装(.+)$", "Installing %@…"),
            ("^正在下载(.+)$", "Downloading %@…"),
            ("^正在校验(.+)$", "Verifying %@…"),
            ("^同时：(.+)$", "Also: %@"),
            ("^(.+)安装完成$", "%@ installation complete"),
            ("^(.+)游戏文件已校验，正在完成安装…$", "%@ game files verified. Finishing installation…"),
            ("^正在检查安装空间并解析(.+)游戏文件…$", "Checking disk space and reading %@ game files…"),
            ("^正在并行准备 IDV Login 与(.+)运行环境…$", "Preparing the IDV Login and %@ runtime in parallel…"),
            ("^正在安全取消共享兼容环境下载并清理临时文件…$", "Safely cancelling the shared compatibility download and cleaning temporary files…"),
            ("^当前安装阶段不支持暂停；(.+)$", "Pause is unavailable during this installation stage; %@"),
            ("^下载控制将在(.+)后可用。$", "Download controls will be available %@."),
            ("^无法更新下载控制：(.+)$", "Could not update download controls: %@"),
            ("^(.+)失败：(.+)$", "%@ failed: %@"),
            ("^无法(.+)：(.+)$", "Could not %@: %@"),
            ("^(.+)\\n\\n错误代码：([A-Z0-9-]+)$", "%@\n\nError code: %@"),
            ("^找不到 Apple Rosetta 安装器，请先更新 macOS 后重试。错误代码：IDV-ENV-103$", "Apple Rosetta could not be found. Update macOS and try again. Error code: IDV-ENV-103"),
            ("^无法打开 Apple Rosetta 安装器：(.+)\\n错误代码：IDV-ENV-103$", "Could not open the Apple Rosetta installer: %@\nError code: IDV-ENV-103"),
            ("^请先(.+)。$", "Please %@."),
            ("^正在启动 IDV Login…$", "Starting IDV Login…"),
            ("^IDV Login 已就绪；本机登录代理可用。$", "IDV Login is ready; the local login proxy is available."),
            ("^IDV Login 已停止。$", "IDV Login has stopped."),
            ("^已跳过 idv-login；之后可随时在启动器中安装。$", "idv-login was skipped. You can install it later from the launcher."),
            ("^已开启“跟随游戏启动”；首次使用前会说明本地证书信任授权。$", "Start with Game is enabled. The launcher will explain local certificate trust before first use."),
            ("^已关闭“跟随游戏启动”；仍可在组件可用时手动启动 IDV Login。$", "Start with Game is disabled. You can still start IDV Login manually when available."),
            ("^当前版本 (.+)。此版本尚未提供自动更新；(.+)$", "Current version %@. Automatic updates are not available yet; %@"),
            ("^第五人格未运行，正在启动…$", "Identity V is not running. Launching…"),
            ("^正在请求麦克风权限（游戏内语音必需），请在系统弹窗上点「允许」。$", "Requesting microphone access for in-game voice. Select Allow in the system prompt."),
            ("^游戏没有进入运行状态，请稍后重试。$", "The game did not start. Please try again."),
            ("^完成 Rosetta 安装后，返回启动器再次点击原来的按钮即可继续。$", "After Rosetta finishes installing, return to the launcher and click the same button to continue."),
            ("^已取消游戏下载；(.+)$", "Game download cancelled; %@"),
            ("^安装游戏失败：(.+)$", "Game installation failed: %@"),
            ("^安装 IDV Login 失败：(.+)$", "IDV Login installation failed: %@"),
            ("^已取消 IDV Login 安装；(.+)$", "IDV Login installation cancelled; %@"),
            ("^请先安装固定的 IDV Login (.+) 组件。$", "Install the pinned IDV Login %@ component first."),
            ("^启动器中缺少(.+)，请重新安装启动器。$", "The launcher is missing %@. Reinstall the launcher."),
            ("^当前游戏会话已变化，已取消重启。请从启动器重新启动。$", "The game session changed, so the restart was cancelled. Restart from the launcher."),
            ("^启动器正在处理其他操作，已取消本次重启。$", "The launcher is busy, so this restart was cancelled."),
            ("^正在收束旧游戏会话并立即重启；IDV Login 保持运行…$", "Closing the previous game session and restarting now; IDV Login will remain running…"),
            ("^已安装的 IDV Login helper 版本过旧；(.+)$", "The installed IDV Login helper is outdated; %@"),
            ("^鼠标加速度实验设置已保存，将在下次启动游戏时生效。$", "Mouse acceleration experiment settings were saved and will apply next time the game starts."),
            ("^已复制启动失败信息；(.+)$", "Launch failure details copied; %@"),
            ("^未找到可用的邮件客户端。日志包已在 Finder 中显示，请用网页邮箱写到 (.+) 并附上该文件；反馈内容已在上方，可复制。$", "No mail app is available. The log bundle is shown in Finder. Email %@ from webmail and attach the file; copy your report above."),
            ("^未找到可用的邮件客户端。请用网页邮箱写到 (.+)。$", "No mail app is available. Email %@ from webmail instead.")
        ]

        for (pattern, format) in templates {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
                  match.range.length == (source as NSString).length else { continue }
            let arguments = (1..<match.numberOfRanges).map { index -> CVarArg in
                guard let range = Range(match.range(at: index), in: source) else { return "" as NSString }
                let captured = (source as NSString).substring(with: NSRange(range, in: source))
                return lookup(captured) as NSString
            }
            return String(format: lookup(format), locale: locale, arguments: arguments)
        }
        return source
    }

    private static var systemLocale: Locale {
        let identifier = Locale.preferredLanguages.first ?? Locale.current.identifier
        return locale(forPreferredLanguageIdentifier: identifier)
    }

    static func locale(forPreferredLanguageIdentifier identifier: String) -> Locale {
        let normalized = identifier.replacingOccurrences(of: "_", with: "-").lowercased()
        if normalized.hasPrefix("zh-hant") || normalized.hasPrefix("zh-tw") ||
            normalized.hasPrefix("zh-hk") || normalized.hasPrefix("zh-mo") {
            return Locale(identifier: "zh-Hant")
        }
        if normalized.hasPrefix("zh") { return Locale(identifier: "zh-Hans") }
        return Locale(identifier: "en")
    }
}
