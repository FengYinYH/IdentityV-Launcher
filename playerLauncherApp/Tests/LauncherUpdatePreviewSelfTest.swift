import Foundation

@main
struct LauncherUpdatePreviewSelfTest {
    @MainActor
    static func main() {
        // Parse only the explicit preview entry point. Ordinary launch, Agent
        // commands and misspelled/extra flags must never select preview mode.
        for language in ["zh-Hans", "zh-Hant", "en"] {
            precondition(LauncherUpdatePreview.language(arguments: ["--preview-launcher-update", "--preview-language", language])?.rawValue == language)
        }
        precondition(LauncherUpdatePreview.language(arguments: ["--preview-launcher-update"]) != nil)
        for arguments in [[], ["agent", "status"], ["--preview-language", "en"],
                          ["--preview-launcher-update", "--preview-language", "system"],
                          ["--preview-launcher-update", "--preview-language", "invalid"],
                          ["--preview-launcher-update", "--preview-language"],
                          ["--preview-launcher-update", "extra"]] {
            precondition(LauncherUpdatePreview.language(arguments: arguments) == nil)
        }
        // The visual fixture has neither a real release asset nor business
        // model. Its update action defaults to a no-op in addition to the UI
        // disabling the preview button.
        let preview = LauncherUpdateView(title: "Preview", message: "", offersUpdate: true, isPreview: true)
        precondition(preview.isPreview && preview.offersUpdate && !preview.isInstalling)
        preview.install()
        print("Update preview entry and isolated fixture checks passed (no windows opened).")
    }
}
