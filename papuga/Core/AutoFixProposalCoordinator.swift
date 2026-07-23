import AppKit
import os
import SwiftUI

struct AutoFixProposalActions {
    var replace: () -> Void
    var dismiss: () -> Void
    var timedOut: () -> Void
    var neverReplace: () -> Void
}

/// Thread-safe mirror of "is a proposal currently on screen and listening for Return/Escape".
/// The AutoFix event tap (running on its own thread) reads `isArmed` synchronously to decide
/// whether to even consider swallowing a keystroke, without hopping to the main actor.
final class AutoFixProposalShortcutGate: @unchecked Sendable {
    static let shared = AutoFixProposalShortcutGate()
    private let armed = OSAllocatedUnfairLock(initialState: false)
    private init() {}

    var isArmed: Bool { armed.withLock { $0 } }
    func arm() { armed.withLock { $0 = true } }
    func disarm() { armed.withLock { $0 = false } }
}

@MainActor
final class AutoFixProposalCoordinator {
    static let shared = AutoFixProposalCoordinator()

    private var panel: AutoFixProposalPanel?
    private var dismissTask: Task<Void, Never>?
    private var primaryShortcutAction: (() -> Void)?
    private var dismissShortcutAction: (() -> Void)?
    private var currentActions: AutoFixProposalActions?
    private let logger = AppLogger.autoFix

    private init() {}

    func show(
        proposal: AutoFixProposal,
        near point: NSPoint,
        duration: TimeInterval = 5,
        actions: AutoFixProposalActions
    ) {
        dismissTask?.cancel()

        let panel = panel ?? makePanel()
        self.panel = panel

        currentActions = actions
        let performReplace: () -> Void = { [weak self] in self?.complete(.accepted) }
        let performDismiss: () -> Void = { [weak self] in self?.complete(.dismissed) }
        let performNeverReplace: () -> Void = { [weak self] in self?.complete(.neverReplace) }

        primaryShortcutAction = performReplace
        dismissShortcutAction = performDismiss

        let screenFrame = visibleScreenFrame(containing: point)
        let layout = AutoFixProposalMetrics.layout(
            for: proposal,
            maxPanelWidth: screenFrame.width - 16
        )

        let view = AutoFixProposalView(
            proposal: proposal,
            layout: layout,
            onReplace: performReplace,
            onDismiss: performDismiss,
            onNeverReplace: performNeverReplace
        )
        panel.contentView = NSHostingView(rootView: view)
        panel.title = proposal.displayTitle
        panel.identifier = NSUserInterfaceItemIdentifier("autofix-proposal-panel")
        panel.setAccessibilityElement(true)
        panel.setAccessibilityRole(.window)
        panel.setAccessibilityLabel(proposal.displayTitle)
        panel.setAccessibilityIdentifier("autofix-proposal-panel")

        let origin = clampedOrigin(for: point, size: layout.size, screenFrame: screenFrame)
        panel.setFrame(NSRect(origin: origin, size: layout.size), display: true)
        panel.orderFrontRegardless()
        AutoFixProposalShortcutGate.shared.arm()

        AppLogger.action(logger, "AutoFix proposal shown at \(origin)")

        dismissTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(duration))
            } catch {
                return
            }
            await MainActor.run {
                self?.complete(.timedOut)
            }
        }
    }

    func dismiss(outcome: AutoFixProposalOutcome? = nil) {
        if let outcome {
            complete(outcome)
        } else {
            hide()
        }
    }

    private func complete(_ outcome: AutoFixProposalOutcome) {
        guard panel?.isVisible == true, let actions = currentActions else { return }
        hide()
        switch outcome {
        case .accepted:
            actions.replace()
        case .dismissed:
            actions.dismiss()
        case .timedOut:
            actions.timedOut()
        case .neverReplace:
            actions.neverReplace()
        }
    }

    private func hide() {
        dismissTask?.cancel()
        dismissTask = nil
        primaryShortcutAction = nil
        dismissShortcutAction = nil
        currentActions = nil
        AutoFixProposalShortcutGate.shared.disarm()
        panel?.orderOut(nil)
    }

    func handleKeyboardShortcut(keyCode: UInt16, flags: CGEventFlags) -> Bool {
        guard panel?.isVisible == true else { return false }
        guard !flags.contains(.maskCommand),
              !flags.contains(.maskControl),
              !flags.contains(.maskAlternate) else {
            return false
        }

        switch keyCode {
        case 0x24, 0x4C: // Return, keypad Enter
            primaryShortcutAction?()
            return true
        case 0x35: // Escape
            dismissShortcutAction?()
            return true
        default:
            return false
        }
    }

    func isMouseOverProposal() -> Bool {
        guard let panel, panel.isVisible else { return false }
        return NSPointInRect(NSEvent.mouseLocation, panel.frame)
    }

    private func makePanel() -> AutoFixProposalPanel {
        let panel = AutoFixProposalPanel(
            contentRect: NSRect(origin: .zero, size: AutoFixProposalMetrics.size),
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

    private func visibleScreenFrame(containing point: NSPoint) -> NSRect {
        NSScreen.screens
            .first { NSMouseInRect(point, $0.frame, false) }?
            .visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
    }

    private func clampedOrigin(for point: NSPoint, size: NSSize, screenFrame: NSRect) -> NSPoint {
        let preferred = NSPoint(x: point.x + 14, y: point.y - size.height - 8)
        let minX = screenFrame.minX + 8
        let maxX = screenFrame.maxX - size.width - 8
        let minY = screenFrame.minY + 8
        let maxY = screenFrame.maxY - size.height - 8

        return NSPoint(
            x: min(max(preferred.x, minX), maxX),
            y: min(max(preferred.y, minY), maxY)
        )
    }
}

private final class AutoFixProposalPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private enum AutoFixProposalMetrics {
    static let size = minimumSize

    private static let minimumSize = NSSize(width: 260, height: 139)
    private static let maximumPanelWidth: CGFloat = 560
    static let panelHorizontalPadding: CGFloat = 14
    static let receiptHorizontalPadding: CGFloat = 6
    static let receiptItemSpacing: CGFloat = 10
    static let receiptArrowWidth: CGFloat = 15
    static let minimumPillWidth: CGFloat = 62
    private static let pillHorizontalPadding: CGFloat = 18

    static func layout(for proposal: AutoFixProposal, maxPanelWidth: CGFloat) -> AutoFixProposalLayout {
        let maxWidth = max(minimumSize.width, min(maxPanelWidth, maximumPanelWidth))
        let sourceNaturalWidth = pillWidth(for: proposal.original)
        let targetNaturalWidth = pillWidth(for: proposal.candidate)
        let availablePillWidth = max(
            minimumPillWidth * 2,
            maxWidth - panelHorizontalPadding * 2 - receiptChromeWidth
        )
        let (sourceWidth, targetWidth) = distributedPillWidths(
            source: sourceNaturalWidth,
            target: targetNaturalWidth,
            available: availablePillWidth
        )
        let naturalPanelWidth = sourceWidth + targetWidth + panelHorizontalPadding * 2 + receiptChromeWidth
        let panelWidth = min(max(minimumSize.width, naturalPanelWidth), maxWidth)

        return AutoFixProposalLayout(
            size: NSSize(width: ceil(panelWidth), height: minimumSize.height),
            sourcePillWidth: floor(sourceWidth),
            targetPillWidth: floor(targetWidth)
        )
    }

    private static var receiptChromeWidth: CGFloat {
        receiptHorizontalPadding * 2 + receiptItemSpacing * 2 + receiptArrowWidth
    }

    private static func pillWidth(for text: String) -> CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        let measuredWidth = (text as NSString).size(withAttributes: [.font: font]).width
        return max(minimumPillWidth, ceil(measuredWidth) + pillHorizontalPadding)
    }

    private static func distributedPillWidths(
        source: CGFloat,
        target: CGFloat,
        available: CGFloat
    ) -> (source: CGFloat, target: CGFloat) {
        let naturalTotal = source + target
        guard naturalTotal > available else {
            return (source, target)
        }

        let sourceExtra = max(0, source - minimumPillWidth)
        let targetExtra = max(0, target - minimumPillWidth)
        let extraTotal = sourceExtra + targetExtra
        let availableExtra = max(0, available - minimumPillWidth * 2)

        guard extraTotal > 0 else {
            return (minimumPillWidth, minimumPillWidth)
        }

        let sourceWidth = minimumPillWidth + availableExtra * (sourceExtra / extraTotal)
        let targetWidth = minimumPillWidth + availableExtra * (targetExtra / extraTotal)
        return (sourceWidth, targetWidth)
    }
}

private struct AutoFixProposalLayout {
    let size: NSSize
    let sourcePillWidth: CGFloat
    let targetPillWidth: CGFloat

    var receiptWidth: CGFloat {
        size.width - AutoFixProposalMetrics.panelHorizontalPadding * 2
    }
}

private struct AutoFixProposalView: View {
    let proposal: AutoFixProposal
    let layout: AutoFixProposalLayout
    let onReplace: () -> Void
    let onDismiss: () -> Void
    let onNeverReplace: () -> Void
    @State private var primaryPulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Text(proposal.displayTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ProposalColors.title)
                    .lineLimit(1)
                    .frame(width: 123, height: 19, alignment: .leading)

                Spacer(minLength: 0)

                dismissProposalButton(action: onDismiss)
            }
            .frame(height: 23)

            ProposalReplacementReceipt(
                source: proposal.original,
                target: proposal.candidate,
                sourcePillWidth: layout.sourcePillWidth,
                targetPillWidth: layout.targetPillWidth,
                width: layout.receiptWidth
            )

            HStack {
                neverReplaceButton(action: onNeverReplace)
                Spacer(minLength: 0)
                replaceProposalButton(action: onReplace)
            }
            .frame(height: 24)
        }
        .padding(.horizontal, AutoFixProposalMetrics.panelHorizontalPadding)
        .padding(.vertical, 10)
        .frame(width: layout.size.width, height: layout.size.height)
        .background(
            ProposalColors.panel.opacity(0.96),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(ProposalColors.panelStroke.opacity(0.95), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.34), radius: 12, x: 0, y: 12)
        .onAppear {
            primaryPulse = true
        }
    }

    private func replaceProposalButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Text("↩")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 24, height: 16)
                Text("Enter")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 26, height: 14)
            }
            .foregroundStyle(ProposalColors.enterForeground)
            .padding(.horizontal, 8)
            .frame(width: 67, height: 24)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(ProposalColors.enterBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white.opacity(primaryPulse ? 0.42 : 0.16), lineWidth: 1)
            )
            .shadow(
                color: ProposalColors.enterBackground.opacity(primaryPulse ? 0.42 : 0.16),
                radius: primaryPulse ? 7 : 2,
                x: 0,
                y: 0
            )
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: primaryPulse)
        .accessibilityIdentifier("autofix-proposal-primary-action")
        .instantTooltip(proposal.primaryActionTooltip)
    }

    private func dismissProposalButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 2) {
                Text("×")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 14, height: 12)
                Text("Esc")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 18, height: 14)
            }
            .foregroundStyle(ProposalColors.keyForeground)
            .padding(4)
            .frame(width: 42, height: 22)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(ProposalColors.keyBackground)
            )
        }
        .buttonStyle(.plain)
        .instantTooltip("Закрити підказку. Її можна повернути протягом 10 секунд. Esc")
        .accessibilityIdentifier("autofix-proposal-dismiss-action")
    }

    private func neverReplaceButton(action: @escaping () -> Void) -> some View {
        Button(proposal.neverActionTitle, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(ProposalColors.keyForeground)
            .lineLimit(1)
            .accessibilityIdentifier("autofix-proposal-never-replace-action")
            .instantTooltip("Додати до словника Papuga й більше не пропонувати цю заміну")
    }
}

private struct ProposalReplacementReceipt: View {
    let source: String
    let target: String
    let sourcePillWidth: CGFloat
    let targetPillWidth: CGFloat
    let width: CGFloat

    var body: some View {
        HStack(spacing: AutoFixProposalMetrics.receiptItemSpacing) {
            receiptPill(
                source,
                width: sourcePillWidth,
                foreground: ProposalColors.receiptSourceText,
                background: ProposalColors.receiptSourceBackground
            )
                .accessibilityIdentifier("autofix-proposal-source")

            Text("→")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(ProposalColors.receiptArrow)
                .frame(width: AutoFixProposalMetrics.receiptArrowWidth, height: 18)
                .accessibilityHidden(true)

            receiptPill(
                target,
                width: targetPillWidth,
                foreground: ProposalColors.receiptTargetText,
                background: ProposalColors.receiptTargetBackground
            )
                .accessibilityIdentifier("autofix-proposal-target")
        }
        .padding(.horizontal, AutoFixProposalMetrics.receiptHorizontalPadding)
        .padding(.vertical, 3)
        .frame(width: width, height: 28)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("autofix-proposal-replacement")
        .accessibilityLabel("Можлива заміна \(source) на \(target)")
    }

    private func receiptPill(
        _ text: String,
        width: CGFloat,
        foreground: Color,
        background: Color
    ) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .truncationMode(.middle)
            .minimumScaleFactor(0.75)
            .frame(width: width, height: 22)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(background)
            )
    }
}

private enum ProposalColors {
    static let panel = Color(red: 38.0 / 255.0, green: 40.0 / 255.0, blue: 36.0 / 255.0)
    static let panelStroke = Color(red: 75.0 / 255.0, green: 81.0 / 255.0, blue: 73.0 / 255.0)
    static let title = Color(red: 241.0 / 255.0, green: 243.0 / 255.0, blue: 238.0 / 255.0)
    static let keyBackground = Color(red: 7.0 / 255.0, green: 58.0 / 255.0, blue: 37.0 / 255.0)
    static let keyForeground = Color(red: 55.0 / 255.0, green: 212.0 / 255.0, blue: 107.0 / 255.0)
    static let enterBackground = Color(red: 46.0 / 255.0, green: 200.0 / 255.0, blue: 102.0 / 255.0)
    static let enterForeground = Color(red: 248.0 / 255.0, green: 255.0 / 255.0, blue: 249.0 / 255.0)
    static let receiptSourceBackground = Color(red: 24.0 / 255.0, green: 27.0 / 255.0, blue: 24.0 / 255.0)
    static let receiptSourceText = Color(red: 239.0 / 255.0, green: 243.0 / 255.0, blue: 238.0 / 255.0)
    static let receiptTargetBackground = Color(red: 19.0 / 255.0, green: 39.0 / 255.0, blue: 26.0 / 255.0)
    static let receiptTargetText = Color(red: 248.0 / 255.0, green: 255.0 / 255.0, blue: 249.0 / 255.0)
    static let receiptArrow = Color(red: 136.0 / 255.0, green: 144.0 / 255.0, blue: 134.0 / 255.0)
}
