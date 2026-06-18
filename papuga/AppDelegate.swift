import AppKit
import Defaults
import KeyboardShortcuts

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    private var hotkeyListener: HotkeyListener?
    private var textSwitchEngine: TextSwitchEngine?
    private(set) var layoutManager: LayoutManager?
    private(set) var clipboardHistoryManager: ClipboardHistoryManager?
    private var autoFixController: AutoFixController?
    private let autoFixCharacterMapper = CharacterMapper()
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
        clipboardHistoryManager.bootstrap { [weak clipboardHistoryManager] in
            clipboardHistoryManager?.startMonitoring()
        }
        self.autoFixController = AutoFixController(
            layoutManager: layoutManager,
            characterMapper: autoFixCharacterMapper
        )
        if Defaults[.autoFixEnabled] {
            AppLogger.action(logger, "AutoFix enabled at launch -> starting controller")
            self.autoFixController?.start()
        }
        isConfigured = true
        AppLogger.post(logger, "configure(layoutManager:) completed")

        if !OnboardingManager.shared.shouldShowOnboarding && Defaults[.openHistoryOnAppLaunch] {
            AppLogger.action(logger, "Opening history window after configuration")
            HistoryWindowController.shared.showHistory()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLogger.pre(logger, "applicationDidFinishLaunching")
        _ = updaterManager
        PapugaEventLog.shared.pruneOldEntries()
        PapugaStatsAggregator.migrateLegacyCountersIfNeeded()
        Defaults[.mistakeObservationEnabled] = true
        Defaults[.grammarObservationBetaEnabled] = true
        ReplacementHistoryStore.shared.bootstrap()
        MistakeObservationStore.shared.bootstrap()
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

        Defaults.observe(.autoFixEnabled) { [weak self] change in
            AppLogger.pre(self?.logger ?? AppLogger.lifecycle, "Observed autoFixEnabled change: \(change.newValue)")
            if change.newValue {
                self?.autoFixController?.start()
                AppLogger.post(self?.logger ?? AppLogger.lifecycle, "AutoFix enabled -> controller started")
            } else {
                self?.autoFixController?.stop()
                AppLogger.post(self?.logger ?? AppLogger.lifecycle, "AutoFix disabled -> controller stopped")
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
                self.ensurePermissionDependentServicesRunning()
                AppLogger.post(self.logger, "Permission status refresh completed")
            }
        } else {
            AppLogger.post(logger, "Onboarding is not required")
            // History window is opened from configure(...) once the SwiftUI scene has
            // materialized layoutManager / clipboardHistoryManager — opening here would
            // race ahead of MenuBarExtra.onAppear and inject nil environment values.
        }
        ensurePermissionDependentServicesRunning()
        AppLogger.post(logger, "applicationDidFinishLaunching completed")
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        PermissionManager.shared.refreshStatus()
        ensurePermissionDependentServicesRunning()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        AppLogger.pre(logger, "applicationShouldHandleReopen (no visible windows)")
        if OnboardingManager.shared.shouldShowOnboarding {
            OnboardingWindowController.shared.showOnboarding {
                PermissionManager.shared.refreshStatus()
                self.ensurePermissionDependentServicesRunning()
            }
        } else {
            HistoryWindowController.shared.showHistory()
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppLogger.pre(logger, "applicationWillTerminate")
        hotkeyListener?.stop()
        autoFixController?.stop()
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

        KeyboardShortcuts.onKeyUp(for: .toggleAutoFix) { [weak self] in
            Defaults[.autoFixEnabled].toggle()
            AppLogger.action(self?.logger ?? AppLogger.lifecycle, "Toggled auto-fix via shortcut -> \(Defaults[.autoFixEnabled])")
        }

        KeyboardShortcuts.onKeyUp(for: .openPapuga) { [weak self] in
            AppLogger.action(self?.logger ?? AppLogger.lifecycle, "Open Papuga via shortcut")
            HistoryWindowController.shared.showHistory()
        }

        KeyboardShortcuts.onKeyUp(for: .undoLastFix) { [weak self] in
            AppLogger.action(self?.logger ?? AppLogger.lifecycle, "Undo last fix via shortcut")
            self?.autoFixController?.undoLastFix()
        }

        AppLogger.post(logger, "setupKeyboardShortcuts completed")
    }

    private func ensurePermissionDependentServicesRunning() {
        if Defaults[.autoFixEnabled] {
            autoFixController?.start()
        }
        if Defaults[.isServiceRunning] && Defaults[.useDoublePress] {
            hotkeyListener?.start()
        }
    }
}
