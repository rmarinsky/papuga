import AppKit
import Combine
import Sparkle

@MainActor
final class UpdaterManager: NSObject, ObservableObject {
    private var updaterController: SPUStandardUpdaterController!

    @Published var canCheckForUpdates = false

    /// Work a relaunch would lose or interrupt; silent installs wait until this is false.
    private let isBusy: () -> Bool
    private var installRetryTimer: Timer?

    init(isBusy: @escaping () -> Bool = { false }) {
        self.isBusy = isBusy
        super.init()
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        updaterController.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
        // The unit-test host builds this through MenuBarView. Started there, a silent
        // update would replace the app bundle under the running tests.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        updaterController.startUpdater()
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }
}

// MARK: - SPUUpdaterDelegate

extension UpdaterManager: SPUUpdaterDelegate {
    /// A menu bar app is rarely quit, so install a downloaded update as soon as the app is idle
    /// instead of waiting for quit/logout. Retries every 60 s while busy.
    nonisolated func updater(
        _: SPUUpdater,
        willInstallUpdateOnQuit _: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        MainActor.assumeIsolated {
            installWhenIdle(immediateInstallHandler)
        }
        return true
    }

    private func installWhenIdle(_ install: @escaping () -> Void) {
        installRetryTimer?.invalidate()
        installRetryTimer = nil
        guard isBusy() else {
            install()
            return
        }
        installRetryTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.installWhenIdle(install)
            }
        }
    }
}

// MARK: - SPUStandardUserDriverDelegate

extension UpdaterManager: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverWillShowModalAlert() {
        Task { @MainActor in
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate _: SUAppcastItem) {
        Task { @MainActor in
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        Task { @MainActor in
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
