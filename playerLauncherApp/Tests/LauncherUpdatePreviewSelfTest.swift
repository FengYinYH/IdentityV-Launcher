import AppKit

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
        _ = NSApplication.shared
        let controller = LauncherUpdateWindowController()
        let panel = controller.window!
        var installs = 0, cancels = 0, dismissals = 0
        controller.install = { installs += 1 }
        controller.cancel = { cancels += 1 }
        controller.dismiss = { dismissals += 1 }
        controller.render(LauncherUpdateState(title: "Preview", message: "", offersUpdate: true, isPreview: true))
        controller.primaryAction()
        precondition(installs == 0 && !panel.isVisible)
        controller.render(LauncherUpdateState(title: "Available", message: "", offersUpdate: true))
        controller.primaryAction()
        precondition(installs == 1)
        controller.render(LauncherUpdateState(title: "", message: "", isInstalling: true, progress: 0.5, canCancel: true))
        precondition(controller.window === panel && !controller.windowShouldClose(panel))
        controller.primaryAction()
        controller.secondaryAction()
        precondition(installs == 1 && cancels == 1 && dismissals == 0)
        controller.render(LauncherUpdateState(title: "", message: "", isInstalling: true, progress: 1, canCancel: false))
        controller.secondaryAction()
        precondition(cancels == 1)
        controller.render(LauncherUpdateState(title: "Failed", message: "Long error", offersUpdate: false))
        controller.primaryAction()
        precondition(dismissals == 1 && controller.window === panel && !panel.isVisible)
        precondition(panel.frame.size == LauncherPanelGeometry.frameSize)
        for message in ["当前版本：1.0.0-rc.5\n最新版本：1.0.0", "Current version: 1.0.0-rc.5\nLatest version: 1.0.0", String(repeating: "Long error message. ", count: 100)] {
            controller.render(LauncherUpdateState(title: "A newer version is available. Update now?", message: message, offersUpdate: true))
            let content = panel.contentView!
            content.layoutSubtreeIfNeeded()
            let buttons = content.subviews.compactMap { $0 as? NSButton }.filter { !$0.isHidden }.sorted { $0.frame.minX < $1.frame.minX }
            precondition(buttons.count == 2 && buttons[1].frame.minX - buttons[0].frame.maxX == 8)
            for child in content.subviews where !child.isHidden {
                precondition(child.frame.minY >= 0 && child.frame.maxY <= content.bounds.height)
            }
            let scroll = content.subviews.compactMap { $0 as? NSScrollView }.first!
            precondition(scroll.hasVerticalScroller == (message.count > 100))
        }
        precondition(!panel.isVisible)
        print("Update preview and retained native panel lifecycle checks passed (no windows shown).")
    }
}
