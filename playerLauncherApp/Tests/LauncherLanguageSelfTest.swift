import Foundation

@main
enum LauncherLanguageSelfTest {
    static func main() {
        let localeCases = [
            ("zh-Hans", "zh-Hans"),
            ("zh_CN", "zh-Hans"),
            ("zh-Hant", "zh-Hant"),
            ("zh-TW", "zh-Hant"),
            ("zh-HK", "zh-Hant"),
            ("zh-MO", "zh-Hant"),
            ("en-US", "en"),
            ("ja-JP", "en")
        ]
        let localeChecks = localeCases.map { input, expected in
            LauncherLanguage.locale(forPreferredLanguageIdentifier: input).identifier == expected
        }
        let defaultsName = "launcher-language-self-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let defaultLanguage = LauncherLanguage.configured(from: defaults) == .system
        defaults.set(LauncherLanguage.english.rawValue, forKey: LauncherLanguage.preferenceKey)
        let storedLanguage = LauncherLanguage.configured(from: defaults) == .english
        defaults.set("future-value", forKey: LauncherLanguage.preferenceKey)
        let invalidValueFallsBack = LauncherLanguage.configured(from: defaults) == .system
        guard let localizationRoot = CommandLine.arguments.dropFirst().first.map({ URL(fileURLWithPath: $0) }),
              let english = loadStrings(localizationRoot.appendingPathComponent("en.lproj/Localizable.strings")),
              let traditional = loadStrings(localizationRoot.appendingPathComponent("zh-Hant.lproj/Localizable.strings")),
              let simplified = loadStrings(localizationRoot.appendingPathComponent("zh-Hans.lproj/Localizable.strings")) else {
            fatalError("Pass the launcher Localization resource directory to this self-test.")
        }
        let englishLookup: (String) -> String = { english[$0] ?? $0 }
        let traditionalLookup: (String) -> String = { traditional[$0] ?? $0 }
        let simplifiedLookup: (String) -> String = { simplified[$0] ?? $0 }
        let translatedInstall = LauncherLanguage.english.localizedMessage("正在安装国服", lookup: englishLookup)
        let translatedFailure = LauncherLanguage.traditionalChinese.localizedMessage("安装游戏失败：磁盘空间不足", lookup: traditionalLookup)
        let translatedCode = LauncherLanguage.english.localizedMessage("Rosetta 不可用\n\n错误代码：IDV-ENV-103", lookup: englishLookup)
        let translatedMailNotice = LauncherLanguage.english.localizedMessage(
            "未找到可用的邮件客户端。请用网页邮箱写到 help@example.test。",
            lookup: englishLookup
        )
        let translatedMicWarning = LauncherLanguage.english.localizedMessage(
            "麦克风尚未授权：首次启动游戏时请在系统弹窗上点「允许」，否则语音会失败并可能卡在「进入大厅」。",
            lookup: englishLookup
        )
        let translatedLoginVersion = String(
            format: englishLookup("版本 %@"),
            locale: LauncherLanguage.english.locale,
            "6.3.1"
        )
        let translatedLoginVersionHans = String(
            format: simplifiedLookup("版本 %@"),
            locale: LauncherLanguage.simplifiedChinese.locale,
            "6.3.1"
        )
        let translatedLoginVersionHant = String(
            format: traditionalLookup("版本 %@"),
            locale: LauncherLanguage.traditionalChinese.locale,
            "6.3.1"
        )
        let translatedUpdateNotice = LauncherLanguage.english.localizedMessage(
            "当前版本 6.3.1。此版本尚未提供自动更新；下载新版安装镜像后，退出启动器并替换应用即可。",
            lookup: englishLookup
        )
        let translationChecks = [
            LauncherLanguage.system.menuTitle(in: .english, lookup: englishLookup) == "Follow System",
            LauncherLanguage.system.menuTitle(in: .simplifiedChinese, lookup: simplifiedLookup) == "跟随系统",
            LauncherLanguage.system.menuTitle(in: .traditionalChinese, lookup: traditionalLookup) == "跟隨系統",
            LauncherLanguage.simplifiedChinese.menuTitle(in: .english, lookup: englishLookup) == "简体中文",
            LauncherLanguage.traditionalChinese.menuTitle(in: .english, lookup: englishLookup) == "繁體中文",
            LauncherLanguage.english.menuTitle(in: .simplifiedChinese, lookup: simplifiedLookup) == "English",
            LauncherLanguage.english.launchLocationCopy.title == english["请先把第五人格启动器拖到应用程序文件夹"],
            LauncherLanguage.english.launchLocationCopy.message == english["请从磁盘映像中拖到“应用程序”后，再打开启动器。"],
            LauncherLanguage.traditionalChinese.launchLocationCopy.title == traditional["请先把第五人格启动器拖到应用程序文件夹"],
            LauncherLanguage.traditionalChinese.launchLocationCopy.message == traditional["请从磁盘映像中拖到“应用程序”后，再打开启动器。"],
            translatedInstall == "Installing Mainland China…",
            translatedFailure == "安裝遊戲失敗：磁盘空间不足",
            translatedCode == "Rosetta 不可用\n\nError code: IDV-ENV-103",
            translatedMailNotice == "No mail app is available. Email help@example.test from webmail instead.",
            translatedMicWarning == "Microphone access is not yet authorized. When the game starts, select Allow in the system prompt; otherwise, voice may fail and the game may get stuck at “Entering Lobby”.",
            translatedLoginVersion == "Version 6.3.1",
            translatedLoginVersionHans == "版本 6.3.1",
            translatedLoginVersionHant == "版本 6.3.1",
            translatedUpdateNotice == "Current version 6.3.1. Automatic updates are not available yet; download the updated installer image, then quit the launcher and replace the app."
        ]
        let checks = localeChecks + [defaultLanguage, storedLanguage, invalidValueFallsBack] + translationChecks
        guard checks.allSatisfy({ $0 }) else {
            FileHandle.standardError.write(Data("Launcher language self-test failed: \(checks)\n".utf8))
            exit(1)
        }
        print("Launcher language selection self-test passed.")
    }

    private static func loadStrings(_ url: URL) -> [String: String]? {
        guard let data = try? Data(contentsOf: url),
              let propertyList = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let strings = propertyList as? [String: String] else { return nil }
        return strings
    }
}
