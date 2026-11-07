import AppKit
import SwiftUI

/// The standard About panel's version line uses the small, regular system font.
/// Share that typography across update states rather than promoting their copy
/// to a headline; controls retain their native button styles.
enum LauncherPanelGeometry {
    // Standard About panel measured on macOS on 2026-11-07, in logical points,
    // including native chrome. Both windows use this contract, not a content width.
    static let frameSize = NSSize(width: 284, height: 191)
}

struct LauncherUpdateView: View {
    @State private var contentSize = NSSize(width: 284, height: 169)
    let title: String
    let message: String
    var isInstalling = false
    var progress: Double = 0
    var canCancel = false
    var offersUpdate = false
    var isPreview = false
    var install: () -> Void = {}
    var cancel: () -> Void = {}
    var dismiss: () -> Void = {}

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable().frame(width: 32, height: 32)
            if isInstalling {
                Text(LocalizedStringKey(progress < 1 ? "正在下载更新…" : "正在校验更新并准备重启…"))
                ProgressView(value: progress)
                if canCancel { Button("取消", role: .cancel, action: cancel) }
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        Text(title).fixedSize(horizontal: false, vertical: true)
                        if !message.isEmpty {
                            Text(message).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if isPreview {
                            Text("仅预览，不会下载或安装更新。")
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                }
                .frame(maxHeight: .infinity)
                HStack {
                    if offersUpdate {
                        Button("取消", role: .cancel, action: dismiss)
                        Spacer()
                        Button("更新", action: install)
                            .buttonStyle(.borderedProminent)
                            .tint(.blue)
                            .keyboardShortcut(.defaultAction)
                            .disabled(isPreview)
                    } else {
                        Spacer()
                        Button("好的", action: dismiss).keyboardShortcut(.defaultAction)
                        Spacer()
                    }
                }
            }
        }
        .font(.system(size: NSFont.smallSystemFontSize, weight: .regular))
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(width: contentSize.width, height: contentSize.height)
        .background(LauncherPanelSizer(contentSize: $contentSize))
        .interactiveDismissDisabled(isInstalling)
    }
}

/// SwiftUI sheets and titled preview windows have different native chrome.
/// Derive their content size from the same *outer* frame rather than assuming a
/// titlebar height. Fixed content prevents long errors from growing the sheet.
private struct LauncherPanelSizer: NSViewRepresentable {
    @Binding var contentSize: NSSize

    func makeNSView(context: Context) -> SizingView { SizingView() }

    func updateNSView(_ view: SizingView, context: Context) {
        view.resize = { window in
            let target = NSRect(origin: window.frame.origin, size: LauncherPanelGeometry.frameSize)
            let size = window.contentRect(forFrameRect: target).size
            DispatchQueue.main.async {
                if contentSize != size { contentSize = size }
                if window.frame.size != target.size { window.setFrame(target, display: true) }
            }
        }
        if let window = view.window { view.resize?(window) }
    }

    final class SizingView: NSView {
        var resize: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { resize?(window) }
        }
    }
}

/// An explicit, isolated visual entry point. It runs before the production App
/// creates a model, preferences migration, update checker, cache or installer.
/// No release fixture is ever assigned to the real update state.
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
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 260),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        parent.title = language.localized("版本与更新")
        parent.isReleasedWhenClosed = false
        let closeDelegate = PreviewWindowDelegate()
        parent.delegate = closeDelegate
        parent.contentView = NSHostingView(rootView:
            Text(language.localized("更新窗口预览"))
                .font(.system(size: NSFont.smallSystemFontSize, weight: .regular))
                .frame(maxWidth: .infinity, maxHeight: .infinity))
        let preview = NSWindow()
        preview.styleMask = [.titled]
        preview.isReleasedWhenClosed = false
        preview.contentView = NSHostingView(rootView: LauncherUpdateView(
            title: language.localized("已检测到新版本，是否更新？"),
            message: String(format: language.localized("当前版本：%@\n最新版本：%@"),
                            LauncherRelease.displayVersion, "1.0.0"),
            offersUpdate: true, isPreview: true,
            dismiss: { app.terminate(nil) })
            .environment(\.locale, language.locale))
        preview.setContentSize(preview.contentView!.fittingSize)
        parent.center()
        parent.makeKeyAndOrderFront(nil)
        parent.beginSheet(preview)
        app.activate(ignoringOtherApps: true)
        withExtendedLifetime(closeDelegate) { app.run() }
    }

    private final class PreviewWindowDelegate: NSObject, NSWindowDelegate {
        func windowWillClose(_ notification: Notification) {
            NSApplication.shared.terminate(nil)
        }
    }
}
