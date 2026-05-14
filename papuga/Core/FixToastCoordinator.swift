import AppKit
import SwiftUI

/// Owns the floating undo-toast NSPanel. Single panel reused across fixes so
/// rapid successive fixes don't pile up windows.
@MainActor
final class FixToastCoordinator {
    static let shared = FixToastCoordinator()

    private var panel: ToastPanel?
    private var dismissTask: Task<Void, Never>?
    private let logger = AppLogger.autoFix

    private init() {}

    func show(
        near point: NSPoint,
        duration: TimeInterval = 2.5,
        replacement: String? = nil,
        onClick: @escaping () -> Void
    ) {
        dismissTask?.cancel()

        let panel = panel ?? makePanel()
        self.panel = panel

        let view = FixToastView(replacement: replacement) { [weak self] in
            self?.dismiss()
            onClick()
        }
        panel.contentView = NSHostingView(rootView: view)

        let size = FixToastView.size
        let origin = NSPoint(x: point.x, y: point.y)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()

        AppLogger.action(logger, "FixToast shown at \(origin)")

        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            await MainActor.run {
                self?.dismiss()
            }
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        panel?.orderOut(nil)
    }

    /// True when the system mouse cursor is currently over the visible toast
    /// panel. Used by `AutoFixController` to suppress its global `mouseDown`
    /// state-reset for clicks that are landing on our own undo button — the
    /// click would otherwise null out `lastFix` before SwiftUI's Button action
    /// runs, defeating the undo path.
    func isMouseOverToast() -> Bool {
        guard let panel, panel.isVisible else { return false }
        return NSPointInRect(NSEvent.mouseLocation, panel.frame)
    }

    private func makePanel() -> ToastPanel {
        let panel = ToastPanel(
            contentRect: NSRect(origin: .zero, size: FixToastView.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        return panel
    }
}

private final class ToastPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
