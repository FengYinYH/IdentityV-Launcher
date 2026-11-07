import AppKit

@main
struct LauncherUpdatePreviewSelfTest {
    @MainActor
    static func main() {
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
        let previewButton = panel.contentView!.subviews.compactMap { $0 as? NSButton }.first!
        precondition(previewButton.isEnabled && !previewButton.isHidden)
        previewButton.performClick(nil)
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

        let cases = [
            ("已检测到新版本，是否更新？", "当前版本：1.0.0-rc.5\n最新版本：1.0.0"),
            ("A new version is available. Update now?", "Current version: 1.0.0-rc.5\nLatest version: 1.0.0"),
            (String(repeating: "Long title ", count: 6), "Current version: 1.0.0-rc.5\nLatest version: 1.0.0"),
            ("Failed", String(repeating: "Long error message. ", count: 100))
        ]
        var ordinaryHeight: CGFloat = 0
        for (index, item) in cases.enumerated() {
            controller.render(LauncherUpdateState(title: item.0, message: item.1, offersUpdate: true, isPreview: true))
            let content = panel.contentView!
            content.layoutSubtreeIfNeeded()
            let chrome = panel.frame.height - content.bounds.height
            let buttons = content.subviews.compactMap { $0 as? NSButton }.filter { !$0.isHidden }.sorted { $0.frame.minX < $1.frame.minX }
            let icon = content.subviews.compactMap { $0 as? NSImageView }.first!
            let title = content.subviews.compactMap { $0 as? NSTextField }.first!
            let scroll = content.subviews.compactMap { $0 as? NSScrollView }.first!
            let rows = scroll.documentView!.subviews.compactMap { $0 as? NSTextField }
            print("Hidden About layout: outer=\(panel.frame.size), icon=\(icon.frame), title=\(title.frame), rows=\(rows.map { $0.frame }), buttons=\(buttons.map { $0.frame }), scroll=\(scroll.hasVerticalScroller)")
            precondition(panel.frame.width == 284 && panel.frame.height >= 191 && panel.frame.height <= 400)
            precondition(buttons.count == 2 && buttons[1].frame.minX - buttons[0].frame.maxX == 8)
            precondition(buttons.allSatisfy { $0.controlSize == .regular && $0.font?.pointSize == NSFont.systemFontSize && $0.frame.height >= $0.intrinsicContentSize.height })
            for child in content.subviews where !child.isHidden {
                precondition(child.frame.minY >= 0 && child.frame.maxY <= content.bounds.height)
            }
            precondition(icon.frame == NSRect(x: 110, y: 40 - chrome, width: 64, height: 64))
            precondition(title.frame.minX == 6 && title.frame.minY + chrome == 112 && title.frame.width == 272)
            precondition(title.font?.pointSize == 14 && NSFontManager.shared.traits(of: title.font!).contains(.boldFontMask))
            precondition(rows.allSatisfy { $0.font?.pointSize == 10 && !NSFontManager.shared.traits(of: $0.font!).contains(.boldFontMask) })
            precondition(rows.allSatisfy { !$0.stringValue.contains("仅预览") && !$0.stringValue.contains("Preview only") })
            precondition(scroll.frame.minY >= title.frame.maxY && scroll.frame.maxY <= buttons[0].frame.minY)
            precondition(scroll.hasVerticalScroller == (index == 3))
            if index == 0 {
                precondition(title.frame.height == 17 && rows[0].frame.height == 13 && rows[1].frame.height == 13)
                precondition(scroll.frame.minY + chrome == 137 && rows[1].frame.minY == 21)
                precondition(panel.frame.height == 211 + buttons[0].frame.height)
                ordinaryHeight = panel.frame.height
            }
            if index == 2 { precondition(panel.frame.height > ordinaryHeight) }
        }
        precondition(controller.window === panel && !panel.isVisible)
        print("Native About metrics, natural height, retained lifecycle and preview action checks passed (no windows shown).")
    }
}
