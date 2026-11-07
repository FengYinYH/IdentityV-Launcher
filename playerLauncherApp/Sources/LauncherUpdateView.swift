import AppKit
import SwiftUI

enum LauncherPanelGeometry {
    // Actual standard About outer frame measured in logical points on macOS.
    static let frameSize = NSSize(width: 284, height: 191)
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

/// One retained native window for both production and preview. Updating its
/// state never recreates the window, steals focus on progress ticks or starts
/// business work. Only the explicitly supplied actions can reach the model.
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
        panel.setFrame(NSRect(origin: .zero, size: LauncherPanelGeometry.frameSize), display: false)
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
        window?.standardWindowButton(.closeButton)?.isEnabled = !state.isInstalling
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
            // Guard here as well as disabling the native button: even an
            // accidental programmatic preview action cannot call an installer.
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

/// A background bridge retains the controller and renders every published
/// model state, including progress, cancellation, late errors and cleanup.
/// It is deliberately independent of the main window's sheet presentation.
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
    static func dismantleNSView(_ view: NSView, coordinator: LauncherUpdateWindowController) {
        coordinator.hide()
    }
}

/// Native controls and measured text keep ordinary results compact. Only text
/// exceeding the available area scrolls; buttons remain adjacent at the right.
@MainActor
private final class UpdatePanelContent: NSView {
    let primary = NSButton()
    let secondary = NSButton()
    private let icon = NSImageView()
    private let scroll = NSScrollView()
    private let text = NSTextView()
    private let progress = NSProgressIndicator()
    private var installing = false

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        icon.image = NSApplication.shared.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(icon)
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = .zero
        text.textContainer?.lineFragmentPadding = 0
        text.isHorizontallyResizable = false
        text.isVerticallyResizable = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.documentView = text
        addSubview(scroll)
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.style = .bar
        addSubview(progress)
        for button in [primary, secondary] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            addSubview(button)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func render(_ state: LauncherUpdateState) {
        installing = state.isInstalling
        let language = state.language
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = 2
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
            .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph
        ]
        let copy = state.isInstalling
            ? language.localized(state.progress < 1 ? "正在下载更新…" : "正在校验更新并准备重启…")
            : [state.title, state.message].filter { !$0.isEmpty }.joined(separator: "\n")
        let attributed = NSMutableAttributedString(string: copy, attributes: attributes)
        if state.isPreview {
            var noteAttributes = attributes
            noteAttributes[.foregroundColor] = NSColor.secondaryLabelColor
            attributed.append(NSAttributedString(string: "\n" + language.localized("仅预览，不会下载或安装更新。"), attributes: noteAttributes))
        }
        text.textStorage?.setAttributedString(attributed)
        progress.isHidden = !state.isInstalling
        progress.doubleValue = min(1, max(0, state.progress))
        primary.title = language.localized(state.offersUpdate ? "更新" : "好的")
        primary.keyEquivalent = "\r"
        primary.isHidden = state.isInstalling
        primary.isEnabled = !state.isPreview
        secondary.title = language.localized("取消")
        secondary.keyEquivalent = "\u{1b}"
        secondary.isHidden = state.isInstalling ? !state.canCancel : !state.offersUpdate
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = bounds.width - 24
        text.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        if let container = text.textContainer { text.layoutManager?.ensureLayout(for: container) }
        let measured = text.textContainer.map { text.layoutManager?.usedRect(for: $0).height ?? 0 } ?? 0
        let buttonHeight: CGFloat = 20
        let progressHeight: CGFloat = installing ? 16 : 0
        let textHeight = min(ceil(measured) + 2, max(14, bounds.height - 80 - progressHeight))
        let totalHeight = 28 + 6 + textHeight + (installing ? 16 : 0) + 10 + buttonHeight
        var y = max(8, (bounds.height - totalHeight) / 2)
        icon.frame = NSRect(x: (bounds.width - 28) / 2, y: y, width: 28, height: 28)
        y += 34
        scroll.frame = NSRect(x: 12, y: y, width: width, height: textHeight)
        text.frame = NSRect(x: 0, y: 0, width: width, height: max(textHeight, ceil(measured) + 2))
        scroll.hasVerticalScroller = measured > textHeight
        y += textHeight + 10
        if installing {
            progress.frame = NSRect(x: 12, y: y, width: width, height: 12)
            y += 16
        }
        var right = bounds.width - 12
        for button in [primary, secondary] where !button.isHidden {
            let buttonWidth = max(54, button.intrinsicContentSize.width)
            button.frame = NSRect(x: right - buttonWidth, y: y, width: buttonWidth, height: buttonHeight)
            right -= buttonWidth + 8
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
