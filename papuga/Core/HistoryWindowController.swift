import AppKit
import SwiftUI

enum HistorySection: String, Identifiable, CaseIterable {
    case clipboard
    case replacements
    case recommendations
    case settingsGeneral
    case settingsHotkeys
    case settingsAutoFix
    case settingsAnalytics
    case settingsAbout

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clipboard: return "Буфер обміну"
        case .replacements: return "Заміни"
        case .recommendations: return "Рекомендації"
        case .settingsGeneral: return "Загальні"
        case .settingsHotkeys: return "Гарячі клавіші"
        case .settingsAutoFix: return "Автозаміна"
        case .settingsAnalytics: return "Аналітика"
        case .settingsAbout: return "Про програму"
        }
    }

    var systemImage: String {
        switch self {
        case .clipboard: return "doc.on.clipboard"
        case .replacements: return "arrow.left.arrow.right"
        case .recommendations: return "sparkles"
        case .settingsGeneral: return "gear"
        case .settingsHotkeys: return "command"
        case .settingsAutoFix: return "wand.and.stars"
        case .settingsAnalytics: return "chart.bar"
        case .settingsAbout: return "info.circle"
        }
    }
}

@MainActor
final class HistoryWindowController {
    static let shared = HistoryWindowController()

    private var window: NSWindow?
    private var hostingView: NSHostingView<AnyView>?
    private var windowDelegate: HistoryWindowDelegate?
    private var selectedSection: HistorySection = .clipboard

    private init() {}

    func showHistory(initialSection: HistorySection? = nil) {
        if let initialSection {
            selectedSection = initialSection
        }

        if let window {
            NotificationCenter.default.post(
                name: .historyWindowSectionRequest,
                object: nil,
                userInfo: ["section": selectedSection]
            )
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let root = AnyView(
            historyRootView(initialSection: selectedSection)
        )
        let hostingView = NSHostingView(rootView: root)
        self.hostingView = hostingView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.title = "Papuga"
        window.contentView = hostingView
        window.minSize = NSSize(width: 760, height: 520)
        window.setContentSize(NSSize(width: 920, height: 640))
        window.center()
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("ua.com.rmarinsky.papuga.history")

        let delegate = HistoryWindowDelegate { [weak self] in
            self?.window = nil
            self?.hostingView = nil
            self?.windowDelegate = nil
        }
        self.windowDelegate = delegate
        window.delegate = delegate

        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private final class HistoryWindowDelegate: NSObject, NSWindowDelegate {
    let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_: Notification) {
        onClose()
    }
}

extension Notification.Name {
    static let historyWindowSectionRequest = Notification.Name("ua.com.rmarinsky.papuga.history.section.request")
}

@MainActor
@ViewBuilder
private func historyRootView(initialSection: HistorySection) -> some View {
    if let layoutManager = AppDelegate.shared?.layoutManager,
       let clipboardHistoryManager = AppDelegate.shared?.clipboardHistoryManager {
        HistoryWindowView(initialSection: initialSection)
            .environment(layoutManager)
            .environment(clipboardHistoryManager)
    } else {
        // The window is only opened from AppDelegate.configure(...) and from menu-bar
        // actions, both of which run after the SwiftUI scene has produced the managers.
        // If we ever land here, surface the misuse instead of crashing on a missing
        // environment value inside HistoryWindowView's subviews.
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text("Не вдалось відкрити вікно: ще не ініціалізовано середовище.")
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}
