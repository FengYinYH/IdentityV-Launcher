import Foundation

/// The accessory helper can only display this text and return an explicit
/// button choice. Product ownership and all game controls stay in the launcher.
///
/// Two shapes travel over the same pipe, distinguished by `kind`:
/// - `hang`: the original "game may be stuck" prompt with its two buttons.
/// - `recovered`: the same incident was observed running again, so the helper
///   shows a countdown and closes itself.
struct HangPromptSnapshot: Codable, Equatable {
    let id: String
    let title: String
    /// Absent in the original one-record protocol; treated as `hang`.
    var kind: String?
    /// Remaining seconds; only present for `recovered`.
    var countdown: Int?
    var language: String?

    init(id: String, title: String, kind: String? = nil, countdown: Int? = nil, language: String? = nil) {
        self.id = id
        self.title = title
        self.kind = kind
        self.countdown = countdown
        self.language = language
    }

    var isRecovery: Bool { kind == "recovered" }
}

struct HangPromptAction: Codable, Equatable {
    let id: String
    let action: String
}

/// Shared wording so the launcher and the helper cannot drift apart, and so the
/// countdown rule (start at 5, tick to 1, then close) is testable without a
/// window.
enum HangPromptRecovery {
    static let firstCountdown = 5

    static func title(countdown: Int, language: String = "zh-Hans") -> String {
        let bounded = max(1, min(firstCountdown, countdown))
        switch language {
        case "zh-Hant": return "偵測到遊戲恢復執行，視窗將在 \(bounded) 秒後關閉"
        case "en": return "Game recovered. This window closes in \(bounded) seconds."
        default: return "检测到游戏恢复运行，窗口将在 \(bounded) 秒后关闭"
        }
    }

    /// Next countdown value, or nil when the window should close.
    static func next(after countdown: Int) -> Int? {
        countdown > 1 ? countdown - 1 : nil
    }

    static func fixtureChecks() -> [Bool] {
        let first = HangPromptSnapshot(id: "recovered-1", title: title(countdown: firstCountdown, language: "en"),
                                       kind: "recovered", countdown: firstCountdown, language: "en")
        let encoded = (try? JSONEncoder().encode(first)) ?? Data()
        let decoded = try? JSONDecoder().decode(HangPromptSnapshot.self, from: encoded)
        // A record without kind/countdown (older shape) must still decode, so an
        // installed helper and a newer launcher can still talk during an update.
        let legacy = try? JSONDecoder().decode(
            HangPromptSnapshot.self,
            from: Data("{\"id\":\"legacy\",\"title\":\"游戏可能卡住了\"}".utf8)
        )
        return [
            decoded == first,
            decoded?.isRecovery == true,
            decoded?.language == "en",
            (decoded?.title.utf8.count ?? 81) <= 80,
            legacy?.isRecovery == false,
            legacy?.countdown == nil,
            legacy?.language == nil,
            title(countdown: 5) == "检测到游戏恢复运行，窗口将在 5 秒后关闭",
            title(countdown: 1) == "检测到游戏恢复运行，窗口将在 1 秒后关闭",
            title(countdown: 0) == "检测到游戏恢复运行，窗口将在 1 秒后关闭",
            title(countdown: 5, language: "en") == "Game recovered. This window closes in 5 seconds.",
            title(countdown: 1, language: "zh-Hant") == "偵測到遊戲恢復執行，視窗將在 1 秒後關閉",
            HangPromptCopy.buttons(language: "en").restart == "Restart Game",
            HangPromptCopy.buttons(language: "zh-Hant").wait == "繼續等待",
            next(after: 5) == 4,
            next(after: 2) == 1,
            next(after: 1) == nil
        ]
    }
}

/// Human-facing helper labels; protocol action names remain stable ASCII.
enum HangPromptCopy {
    static func buttons(language: String?) -> (restart: String, wait: String) {
        switch language {
        case "en": return ("Restart Game", "Keep Waiting")
        case "zh-Hant": return ("重新啟動遊戲", "繼續等待")
        default: return ("重启游戏", "继续等")
        }
    }
}
