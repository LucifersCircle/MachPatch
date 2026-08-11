import AppKit
import SwiftUI

extension View {
    @ViewBuilder
    func machPatchToolbarTitleHidden() -> some View {
        if #available(macOS 15.0, *) {
            toolbar(removing: .title)
        } else {
            background(WindowTitleVisibilityBridge())
        }
    }
}

private struct WindowTitleVisibilityBridge: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowTitleVisibilityView {
        WindowTitleVisibilityView()
    }

    func updateNSView(_ nsView: WindowTitleVisibilityView, context: Context) {
        nsView.hideTitle()
    }

    static func dismantleNSView(
        _ nsView: WindowTitleVisibilityView,
        coordinator: Void
    ) {
        nsView.restoreTitleVisibility()
    }
}

private final class WindowTitleVisibilityView: NSView {
    private weak var configuredWindow: NSWindow?
    private var originalTitleVisibility: NSWindow.TitleVisibility?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hideTitle()
    }

    func hideTitle() {
        guard let window else { return }
        if configuredWindow !== window {
            restoreTitleVisibility()
            configuredWindow = window
            originalTitleVisibility = window.titleVisibility
        }
        window.titleVisibility = .hidden
    }

    func restoreTitleVisibility() {
        guard
            let configuredWindow,
            let originalTitleVisibility
        else { return }
        configuredWindow.titleVisibility = originalTitleVisibility
        self.configuredWindow = nil
        self.originalTitleVisibility = nil
    }
}
