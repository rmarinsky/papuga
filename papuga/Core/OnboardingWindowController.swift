import AppKit
import SwiftUI

final class OnboardingWindowController {
    static let shared = OnboardingWindowController()

    private var window: NSWindow?
    private var hostingView: NSHostingView<AnyView>?
    private var windowDelegate: OnboardingWindowDelegate?

    private init() {}

    func showOnboarding(completion: @escaping () -> Void) {
        guard window == nil else {
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let onboardingView = OnboardingContainerView(
            onComplete: {
                OnboardingManager.shared.hasCompletedOnboarding = true
                OnboardingManager.shared.forceShowOnboarding = false
                self.closeOnboarding()
                completion()
            }
        )

        let hostingView = NSHostingView(rootView: AnyView(onboardingView))
        self.hostingView = hostingView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        window.title = "Papuga"
        window.contentView = hostingView
        window.minSize = NSSize(width: 520, height: 560)
        window.setContentSize(NSSize(width: 560, height: 620))
        window.center()
        window.isReleasedWhenClosed = false

        self.windowDelegate = OnboardingWindowDelegate(onClose: {
            OnboardingManager.shared.forceShowOnboarding = false
            self.window = nil
            self.windowDelegate = nil
            completion()
        })
        window.delegate = self.windowDelegate

        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func closeOnboarding() {
        window?.close()
        window = nil
        windowDelegate = nil
    }
}

private final class OnboardingWindowDelegate: NSObject, NSWindowDelegate {
    let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_: Notification) {
        onClose()
    }
}
