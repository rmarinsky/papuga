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

    func show(near point: NSPoint, duration: TimeInterval = 2.5, onClick: @escaping () -> Void) {
        dismissTask?.cancel()

        let panel = panel ?? makePanel()
        self.panel = panel

        let view = FixToastView { [weak self] in
            self?.dismiss()
            onClick()
        }
        panel.contentView = NSHostingView(rootView: view)
        panel.title = "Скасувати заміну"
        panel.identifier = NSUserInterfaceItemIdentifier("autofix-undo-panel")
        panel.setAccessibilityElement(true)
        panel.setAccessibilityRole(.window)
        panel.setAccessibilityLabel("Скасувати заміну")
        panel.setAccessibilityIdentifier("autofix-undo-panel")

        show(panel: panel, size: NSSize(width: 50, height: 50), near: point)
        scheduleDismiss(after: duration)

        AppLogger.action(logger, "FixToast shown")
    }

    func showRecovery(
        title: String,
        near point: NSPoint,
        duration: TimeInterval = 10,
        onClick: @escaping () -> Void
    ) {
        dismissTask?.cancel()

        let panel = panel ?? makePanel()
        self.panel = panel
        let view = FixRecoveryView(title: title) { [weak self] in
            self?.dismiss()
            onClick()
        }
        panel.contentView = NSHostingView(rootView: view)
        panel.title = title
        panel.identifier = NSUserInterfaceItemIdentifier("autofix-recovery-panel")
        panel.setAccessibilityElement(true)
        panel.setAccessibilityRole(.window)
        panel.setAccessibilityLabel(title)
        panel.setAccessibilityIdentifier("autofix-recovery-panel")

        let width = max(150, (title as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold)
        ]).width + 58)
        show(panel: panel, size: NSSize(width: ceil(width), height: 34), near: point)
        scheduleDismiss(after: duration)

        AppLogger.action(logger, "Fix recovery shown: \(title)")
    }

    private func show(panel: ToastPanel, size: NSSize, near point: NSPoint) {
        let origin = NSPoint(x: point.x + 14, y: point.y - size.height - 6)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }

    private func scheduleDismiss(after duration: TimeInterval) {
        dismissTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(duration))
            } catch {
                return
            }
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
            contentRect: NSRect(x: 0, y: 0, width: 50, height: 50),
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
