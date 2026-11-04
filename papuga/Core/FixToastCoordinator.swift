import AppKit
import SwiftUI

/// Owns the floating undo-toast NSPanel. Single panel reused across fixes so
/// rapid successive fixes don't pile up windows.
@MainActor
final class FixToastCoordinator {
    static let shared = FixToastCoordinator()

    private var panel: ToastPanel?
    private var dismissTask: Task<Void, Never>?
    /// The deferred chip lives in its own panel with its own lifetime: the
    /// shared toast panel is dismissed on every keystroke via `clearRecovery()`,
    /// and surviving typing is the chip's whole reason to exist.
    private var chipPanel: ToastPanel?
    private var chipDismissTask: Task<Void, Never>?
    private let logger = AppLogger.autoFix

    private init() {}

    func show(near point: NSPoint, duration: TimeInterval = 2.5, onClick: (() -> Void)? = nil) {
        dismissTask?.cancel()

        let panel = panel ?? makePanel()
        self.panel = panel

        let view = FixToastView(onClick: onClick.map { action in
            { [weak self] in
                self?.dismiss()
                action()
            }
        })
        panel.contentView = NSHostingView(rootView: view)
        panel.ignoresMouseEvents = onClick == nil
        panel.title = onClick == nil ? "Papuga" : "Скасувати заміну"
        panel.identifier = NSUserInterfaceItemIdentifier("autofix-undo-panel")
        panel.setAccessibilityElement(true)
        panel.setAccessibilityRole(.window)
        panel.setAccessibilityLabel(panel.title)
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
        panel.ignoresMouseEvents = false
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

        AppLogger.action(logger, "Fix recovery shown: titleLength=\(title.count)")
    }

    func showDeferredChip(
        original: String,
        candidate: String,
        near point: NSPoint,
        timeToLive: TimeInterval,
        onApply: @escaping () -> Void,
        onDismiss: @escaping () -> Void,
        onExpire: @escaping () -> Void
    ) {
        chipDismissTask?.cancel()

        let panel = chipPanel ?? makePanel()
        chipPanel = panel
        panel.ignoresMouseEvents = false

        let receipt = "\(original) → \(candidate)"
        let width = min(360, max(170, (receipt as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold)
        ]).width + 76)).rounded(.up)

        let view = DeferredFixChipView(
            original: original,
            candidate: candidate,
            width: width,
            timeToLive: timeToLive,
            onApply: { [weak self] in
                self?.dismissChip()
                onApply()
            },
            onDismiss: { [weak self] in
                self?.dismissChip()
                onDismiss()
            }
        )
        let hosting = NSHostingView(rootView: view)
        // The panel is the authority on size; the hosting view must not push a
        // resize back onto its window while the drain animation is running.
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: DeferredFixChipView.height)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        panel.title = "Застосувати відкладену підказку"
        panel.identifier = NSUserInterfaceItemIdentifier("autofix-chip-panel")
        panel.setAccessibilityElement(true)
        panel.setAccessibilityRole(.window)
        panel.setAccessibilityLabel(panel.title)
        panel.setAccessibilityIdentifier("autofix-chip-panel")

        show(panel: panel, size: NSSize(width: width, height: DeferredFixChipView.height), near: point)

        chipDismissTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(timeToLive))
            } catch {
                return
            }
            await MainActor.run {
                self?.dismissChip()
                onExpire()
            }
        }

        AppLogger.action(logger, "Deferred chip shown: ttl=\(String(format: "%.1f", timeToLive))s")
    }

    func dismissChip() {
        chipDismissTask?.cancel()
        chipDismissTask = nil
        chipPanel?.orderOut(nil)
    }

    func isMouseOverChip() -> Bool {
        guard let chipPanel, chipPanel.isVisible else { return false }
        return NSPointInRect(NSEvent.mouseLocation, chipPanel.frame)
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
        guard let panel, panel.isVisible, !panel.ignoresMouseEvents else { return false }
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
