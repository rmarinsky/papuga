import AppKit
import SwiftUI

enum HistorySection: String, Identifiable, CaseIterable {
    case overview
    case history
    case suggestions
    case settingsGeneral
    case settingsLanguages
    case settingsRules
    case settingsDictionary
    case settingsShortcuts
    case settingsAccount

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Огляд"
        case .history: return "Історія"
        case .suggestions: return "Поради"
        case .settingsGeneral: return "Загальні"
        case .settingsLanguages: return "Мови"
        case .settingsRules: return "Правила"
        case .settingsDictionary: return "Словник"
        case .settingsShortcuts: return "Клавіші"
        case .settingsAccount: return "Аккаунт"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .history: return "clock.arrow.circlepath"
        case .suggestions: return "sparkles"
        case .settingsGeneral: return "gear"
        case .settingsLanguages: return "globe"
        case .settingsRules: return "wand.and.stars"
        case .settingsDictionary: return "character.book.closed"
        case .settingsShortcuts: return "command"
        case .settingsAccount: return "person.circle"
        }
    }
}

@MainActor
final class HistoryWindowController {
    static let shared = HistoryWindowController()

    private var window: NSWindow?
    private var hostingView: NSHostingView<AnyView>?
    private var windowDelegate: HistoryWindowDelegate?
    private var selectedSection: HistorySection = .overview

    private init() {}

    func showHistory(initialSection: HistorySection? = nil) {
        if let initialSection {
            selectedSection = initialSection
        }

        // Promote to a regular app while the window is up so Papuga shows in the
        // Dock and the ⌘-Tab switcher; we drop back to .accessory on close.
        NSApp.setActivationPolicy(.regular)

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
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.title = "Papuga"
        window.contentView = hostingView
        window.minSize = NSSize(width: 800, height: 560)
        window.setContentSize(NSSize(width: 1000, height: 680))
        window.setFrameAutosaveName("papuga.main")
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
        // Back to a menu-bar-only agent once the window is gone.
        NSApp.setActivationPolicy(.accessory)
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
