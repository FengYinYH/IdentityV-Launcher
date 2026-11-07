import AppKit
import SwiftUI

enum LauncherAboutMetrics {
    // Public standard About view-tree measurement, 2026-11-07. These are actual
    // NSView frames and NSFont sizes, not inferred AX focus bounds. About stays
    // system-owned; only the update window mirrors its upper layout.
    static let width: CGFloat = 284
    static let minimumHeight: CGFloat = 191
    static let iconViewFrame = NSRect(x: 110, y: 40, width: 64, height: 64)
    static let titleFrame = NSRect(x: 6, y: 112, width: 272, height: 17)
    static let titleFontSize: CGFloat = 14
    static let bodyFontSize: CGFloat = 10
    static let bodyRowHeight: CGFloat = 13
    static let rowGap: CGFloat = 8
    static let bottomPadding: CGFloat = 20
    static let maximumMessageHeight: CGFloat = 160
}

struct LauncherUpdateState: Equatable {
    let title: String
    let message: String
    var isInstalling = false
    var progress: Double = 0
    var canCancel = false
    var offersUpdate = false
    var isPreview = false
    var language = LauncherLanguage.current
}

/// One retained native window for both production and preview. State rendering
/// never recreates it or steals focus on progress ticks. Explicit actions are
/// the only bridge to business work; preview guards apply to the real button.
@MainActor
final class LauncherUpdateWindowController: NSWindowController, NSWindowDelegate {
    private let content = UpdatePanelContent()
    private(set) var state = LauncherUpdateState(title: "", message: "")
    var install: () -> Void = {}
    var cancel: () -> Void = {}
    var dismiss: () -> Void = {}

    init() {
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: panel)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = .windowBackgroundColor
        panel.contentView = content
        panel.delegate = self
        panel.setFrame(NSRect(x: 0, y: 0, width: LauncherAboutMetrics.width, height: LauncherAboutMetrics.minimumHeight), display: false)
        panel.center()
        content.primary.target = self
        content.primary.action = #selector(primaryAction)
        content.secondary.target = self
        content.secondary.action = #selector(secondaryAction)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func render(_ state: LauncherUpdateState) {
        guard self.state != state else { return }
        self.state = state
        content.render(state)
        if let window {
            let height = content.requiredOuterHeight
            // Extend down from the existing top instead of compressing About's
            // upper layout or shifting its icon when the message changes.
            window.setFrame(NSRect(x: window.frame.minX, y: window.frame.maxY - height,
                                   width: LauncherAboutMetrics.width, height: height), display: true)
            window.standardWindowButton(.closeButton)?.isEnabled = !state.isInstalling
        }
    }

    func present() {
        if window?.isVisible != true { showWindow(nil) }
    }
    func hide() { window?.orderOut(nil) }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !state.isInstalling else { return false }
        dismiss()
        return true
    }

    @objc func primaryAction() {
        guard !state.isInstalling else { return }
        if state.offersUpdate {
            // Preview draws the real available-state button. This guard,
            // rather than a different visual state, isolates its action.
            guard !state.isPreview else { return }
            install()
        } else { dismiss() }
    }

    @objc func secondaryAction() {
        if state.isInstalling {
            if state.canCancel { cancel() }
        } else { dismiss() }
    }
}

/// Retain the controller and render every published state, including progress,
/// cancellation and late errors, independently of main-window sheets.
struct LauncherUpdateWindowPresenter: NSViewRepresentable {
    @Binding var isPresented: Bool
    var state: LauncherUpdateState
    var install: () -> Void
    var cancel: () -> Void

    func makeCoordinator() -> LauncherUpdateWindowController { LauncherUpdateWindowController() }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        let controller = context.coordinator
        controller.install = install
        controller.cancel = cancel
        controller.dismiss = { isPresented = false }
        controller.render(state)
        if isPresented { controller.present() } else { controller.hide() }
    }
    static func dismantleNSView(_ view: NSView, coordinator: LauncherUpdateWindowController) { coordinator.hide() }
}

@MainActor
private final class UpdateMessageDocument: NSView {
    override var isFlipped: Bool { true }
}

/// Mirror About's separate native labels. Wrapped titles and extra version
/// rows increase the window height; only oversized error messages scroll.
@MainActor
private final class UpdatePanelContent: NSView {
    let primary = NSButton()
    let secondary = NSButton()
    private let icon = NSImageView()
    private let title = NSTextField(wrappingLabelWithString: "")
    private let scroll = NSScrollView()
    private let document = UpdateMessageDocument()
    private var lines: [NSTextField] = []
    private let progress = NSProgressIndicator()
    private var installing = false

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        icon.image = NSApplication.shared.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(icon)
        title.font = .systemFont(ofSize: LauncherAboutMetrics.titleFontSize, weight: .bold)
        title.alignment = .center
        title.maximumNumberOfLines = 0
        addSubview(title)
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.documentView = document
        addSubview(scroll)
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.style = .bar
        addSubview(progress)
        for button in [primary, secondary] {
            button.bezelStyle = .rounded
            button.controlSize = .regular
            button.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            addSubview(button)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func render(_ state: LauncherUpdateState) {
        installing = state.isInstalling
        let language = state.language
        title.stringValue = state.isInstalling
            ? language.localized(state.progress < 1 ? "正在下载更新…" : "正在校验更新并准备重启…")
            : state.title
        for line in lines { line.removeFromSuperview() }
        lines = []
        if !state.isInstalling && !state.message.isEmpty {
            for copy in state.message.components(separatedBy: "\n") {
                let field = NSTextField(wrappingLabelWithString: copy)
                field.font = .systemFont(ofSize: LauncherAboutMetrics.bodyFontSize, weight: .regular)
                field.alignment = .center
                field.isSelectable = true
                field.maximumNumberOfLines = 0
                document.addSubview(field)
                lines.append(field)
            }
        }
        progress.isHidden = !state.isInstalling
        progress.doubleValue = min(1, max(0, state.progress))
        primary.title = language.localized(state.offersUpdate ? "更新" : "好的")
        primary.keyEquivalent = "\r"
        primary.isHidden = state.isInstalling
        secondary.title = language.localized("取消")
        secondary.keyEquivalent = "\u{1b}"
        secondary.isHidden = state.isInstalling ? !state.canCancel : !state.offersUpdate
        needsLayout = true
    }

    private func height(of field: NSTextField, width: CGFloat, minimum: CGFloat) -> CGFloat {
        field.preferredMaxLayoutWidth = width
        let measured = field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 100_000)).height ?? minimum
        return max(minimum, ceil(measured))
    }

    private var titleHeight: CGFloat {
        height(of: title, width: LauncherAboutMetrics.titleFrame.width, minimum: LauncherAboutMetrics.titleFrame.height)
    }

    private var messageHeight: CGFloat {
        var result: CGFloat = 0
        for (index, line) in lines.enumerated() {
            // Match About's version row x=6/w=272 and second row x=8/w=268.
            let width: CGFloat = index == 0 ? 272 : 268
            result += height(of: line, width: width, minimum: LauncherAboutMetrics.bodyRowHeight)
            if index + 1 < lines.count { result += LauncherAboutMetrics.rowGap }
        }
        return result
    }

    private var messageTop: CGFloat {
        LauncherAboutMetrics.titleFrame.minY + titleHeight + (lines.isEmpty ? 0 : LauncherAboutMetrics.rowGap)
    }

    private var buttonTop: CGFloat {
        let bodyEnd = messageTop + min(messageHeight, LauncherAboutMetrics.maximumMessageHeight)
        return bodyEnd + (installing ? 20 : 0) + LauncherAboutMetrics.bottomPadding
    }

    private var buttonHeight: CGFloat {
        ceil(max(primary.intrinsicContentSize.height, secondary.intrinsicContentSize.height))
    }

    var requiredOuterHeight: CGFloat {
        max(LauncherAboutMetrics.minimumHeight, buttonTop + buttonHeight + LauncherAboutMetrics.bottomPadding)
    }

    override func layout() {
        super.layout()
        let chrome = (window?.frame.height ?? bounds.height) - bounds.height
        var iconFrame = LauncherAboutMetrics.iconViewFrame
        iconFrame.origin.y -= chrome
        icon.frame = iconFrame
        var titleFrame = LauncherAboutMetrics.titleFrame
        titleFrame.origin.y -= chrome
        titleFrame.size.height = titleHeight
        title.frame = titleFrame
        let messageFullHeight = messageHeight
        let visibleHeight = min(messageFullHeight, LauncherAboutMetrics.maximumMessageHeight)
        scroll.isHidden = lines.isEmpty
        scroll.frame = NSRect(x: 6, y: messageTop - chrome, width: 272, height: visibleHeight)
        document.frame = NSRect(x: 0, y: 0, width: 272, height: messageFullHeight)
        var y: CGFloat = 0
        for (index, line) in lines.enumerated() {
            let inset: CGFloat = index == 0 ? 0 : 2
            let width = 272 - inset * 2
            let lineHeight = height(of: line, width: width, minimum: LauncherAboutMetrics.bodyRowHeight)
            line.frame = NSRect(x: inset, y: y, width: width, height: lineHeight)
            y += lineHeight + LauncherAboutMetrics.rowGap
        }
        scroll.hasVerticalScroller = messageFullHeight > visibleHeight
        if installing {
            progress.frame = NSRect(x: 12, y: messageTop - chrome + 8, width: 260, height: 12)
        }
        var right = bounds.width - 12
        for button in [primary, secondary] where !button.isHidden {
            let width = max(54, button.intrinsicContentSize.width)
            button.frame = NSRect(x: right - width, y: buttonTop - chrome, width: width, height: buttonHeight)
            right -= width + 8
        }
    }
}

/// Explicit pure visual entry before App/model creation. There is exactly one
/// native panel, with the same controller and controls as the production flow.
@MainActor
enum LauncherUpdatePreview {
    static func language(arguments: [String]) -> LauncherLanguage? {
        guard arguments.first == "--preview-launcher-update" else { return nil }
        if arguments.count == 1 { return .current }
        guard arguments.count == 3, arguments[1] == "--preview-language",
              let language = LauncherLanguage(rawValue: arguments[2]), language != .system else { return nil }
        return language
    }

    static func run(language: LauncherLanguage) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let controller = LauncherUpdateWindowController()
        controller.dismiss = { app.terminate(nil) }
        controller.render(LauncherUpdateState(
            title: language.localized("已检测到新版本，是否更新？"),
            message: String(format: language.localized("当前版本：%@\n最新版本：%@"), LauncherRelease.displayVersion, "1.0.0"),
            offersUpdate: true, isPreview: true, language: language))
        controller.present()
        app.activate(ignoringOtherApps: true)
        withExtendedLifetime(controller) { app.run() }
    }
}
