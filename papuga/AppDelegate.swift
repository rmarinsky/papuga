import AppKit
import Defaults
import KeyboardShortcuts

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotkeyListener: HotkeyListener?
    private var textSwitchEngine: TextSwitchEngine?
    private var layoutManager: LayoutManager?
    private var clipboardHistoryManager: ClipboardHistoryManager?
    private var isConfigured = false
    private let logger = AppLogger.lifecycle
    lazy var updaterManager = UpdaterManager()

    func configure(layoutManager: LayoutManager, clipboardHistoryManager: ClipboardHistoryManager) {
        AppLogger.pre(logger, "configure(layoutManager:) called")
        guard !isConfigured else {
            AppLogger.action(logger, "configure(layoutManager:) skipped: already configured")
            return
        }
        self.layoutManager = layoutManager
        self.clipboardHistoryManager = clipboardHistoryManager
        AppLogger.action(logger, "Creating TextSwitchEngine")
        self.textSwitchEngine = TextSwitchEngine(
            layoutManager: layoutManager,
            clipboardHistoryManager: clipboardHistoryManager
        )
        clipboardHistoryManager.startMonitoring()
        isConfigured = true
        AppLogger.post(logger, "configure(layoutManager:) completed")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLogger.pre(logger, "applicationDidFinishLaunching")
        _ = updaterManager
        setupHotkeyListener()
        setupKeyboardShortcuts()
        AppLogger.action(logger, "Hotkey listener and keyboard shortcuts setup complete")

        Defaults.observe(.isServiceRunning) { [weak self] change in
            AppLogger.pre(self?.logger ?? AppLogger.lifecycle, "Observed isServiceRunning change: \(change.newValue)")
            if change.newValue {
                self?.hotkeyListener?.start()
                AppLogger.post(self?.logger ?? AppLogger.lifecycle, "Service enabled -> hotkey listener started")
            } else {
                self?.hotkeyListener?.stop()
                AppLogger.post(self?.logger ?? AppLogger.lifecycle, "Service disabled -> hotkey listener stopped")
            }
        }.tieToLifetime(of: self)

        Defaults.observe(.useDoublePress) { [weak self] change in
            AppLogger.pre(self?.logger ?? AppLogger.lifecycle, "Observed useDoublePress change: \(change.newValue)")
            if change.newValue {
                self?.hotkeyListener?.start()
                KeyboardShortcuts.disable(.switchForward)
                AppLogger.post(self?.logger ?? AppLogger.lifecycle, "Double-press enabled -> listener started, custom shortcut disabled")
            } else {
                self?.hotkeyListener?.stop()
                KeyboardShortcuts.enable(.switchForward)
                AppLogger.post(self?.logger ?? AppLogger.lifecycle, "Double-press disabled -> listener stopped, custom shortcut enabled")
            }
        }.tieToLifetime(of: self)

        // Show onboarding if needed
        AppLogger.pre(logger, "Checking onboarding precondition")
        if OnboardingManager.shared.shouldShowOnboarding {
            AppLogger.action(logger, "Showing onboarding window")
            OnboardingWindowController.shared.showOnboarding {
                AppLogger.action(self.logger, "Refreshing permission status after onboarding")
                PermissionManager.shared.refreshStatus()
                AppLogger.post(self.logger, "Permission status refresh completed")
            }
        } else {
            AppLogger.post(logger, "Onboarding is not required")
        }
        AppLogger.post(logger, "applicationDidFinishLaunching completed")
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppLogger.pre(logger, "applicationWillTerminate")
        hotkeyListener?.stop()
        clipboardHistoryManager?.stopMonitoring()
        AppLogger.post(logger, "Hotkey listener stopped on termination")
    }

    private func setupHotkeyListener() {
        AppLogger.pre(logger, "setupHotkeyListener")
        let listener = HotkeyListener()
        listener.onSwitch = { [weak self] direction in
            AppLogger.action(self?.logger ?? AppLogger.lifecycle, "HotkeyListener emitted switch event: \(String(describing: direction))")
            self?.textSwitchEngine?.performSwitch(direction: direction)
        }

        if Defaults[.isServiceRunning] && Defaults[.useDoublePress] {
            AppLogger.action(logger, "Preconditions met -> starting HotkeyListener")
            listener.start()
            AppLogger.post(logger, "HotkeyListener started")
        } else {
            AppLogger.warn(logger, "HotkeyListener not started: isServiceRunning=\(Defaults[.isServiceRunning]), useDoublePress=\(Defaults[.useDoublePress])")
        }

        hotkeyListener = listener
        AppLogger.post(logger, "setupHotkeyListener completed")
    }

    private func setupKeyboardShortcuts() {
        AppLogger.pre(logger, "setupKeyboardShortcuts")
        KeyboardShortcuts.onKeyUp(for: .switchForward) { [weak self] in
            AppLogger.pre(self?.logger ?? AppLogger.lifecycle, "Custom shortcut keyUp received")
            guard !Defaults[.useDoublePress] else {
                AppLogger.warn(self?.logger ?? AppLogger.lifecycle, "Custom shortcut ignored: useDoublePress=true")
                return
            }
            AppLogger.action(self?.logger ?? AppLogger.lifecycle, "Triggering switch from custom shortcut")
            self?.textSwitchEngine?.performSwitch(direction: .forward)
            AppLogger.post(self?.logger ?? AppLogger.lifecycle, "Custom shortcut switch request dispatched")
        }
        AppLogger.post(logger, "setupKeyboardShortcuts completed")
    }
}
