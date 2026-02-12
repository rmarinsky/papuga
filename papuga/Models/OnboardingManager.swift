import Foundation
import SwiftUI

// MARK: - Onboarding Step

enum OnboardingStep: Int, Codable, CaseIterable {
    case welcome = 0
    case accessibilityPermission = 1
    case inputMonitoringPermission = 2
    case complete = 3

    var displayName: String {
        switch self {
        case .welcome: return "Вітання"
        case .accessibilityPermission: return "Доступність"
        case .inputMonitoringPermission: return "Введення"
        case .complete: return "Готово"
        }
    }

    var next: OnboardingStep? {
        OnboardingStep(rawValue: rawValue + 1)
    }

    var previous: OnboardingStep? {
        OnboardingStep(rawValue: rawValue - 1)
    }
}

// MARK: - Onboarding Manager

@Observable
final class OnboardingManager {
    static let shared = OnboardingManager()

    private let hasCompletedOnboardingKey = "onboarding.completed"
    private let onboardingVersionKey = "onboarding.version"
    private let currentStepKey = "onboarding.currentStep"
    private let currentOnboardingVersion = 1

    private let stepCompletedPrefix = "onboarding.step."

    var forceShowOnboarding = false

    var currentStep: OnboardingStep {
        get {
            let rawValue = UserDefaults.standard.integer(forKey: currentStepKey)
            return OnboardingStep(rawValue: rawValue) ?? .welcome
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: currentStepKey)
        }
    }

    var hasCompletedOnboarding: Bool {
        get {
            let completedVersion = UserDefaults.standard.integer(forKey: onboardingVersionKey)
            let hasCompleted = UserDefaults.standard.bool(forKey: hasCompletedOnboardingKey)
            return hasCompleted && completedVersion >= currentOnboardingVersion
        }
        set {
            UserDefaults.standard.set(newValue, forKey: hasCompletedOnboardingKey)
            if newValue {
                UserDefaults.standard.set(currentOnboardingVersion, forKey: onboardingVersionKey)
                currentStep = .complete
            }
        }
    }

    var isFirstLaunch: Bool {
        !UserDefaults.standard.bool(forKey: hasCompletedOnboardingKey)
    }

    var shouldShowOnboarding: Bool {
        if forceShowOnboarding {
            return true
        }

        if hasCompletedOnboarding {
            return false
        }

        return true
    }

    private init() {}

    // MARK: - Step Management

    func completeStep(_ step: OnboardingStep) {
        UserDefaults.standard.set(true, forKey: stepCompletedPrefix + "\(step.rawValue)")

        if let next = step.next {
            currentStep = next
        }
    }

    func isStepCompleted(_ step: OnboardingStep) -> Bool {
        UserDefaults.standard.bool(forKey: stepCompletedPrefix + "\(step.rawValue)")
    }

    func skipToStep(_ step: OnboardingStep) {
        currentStep = step
    }

    // MARK: - Reset

    func reset() {
        UserDefaults.standard.removeObject(forKey: hasCompletedOnboardingKey)
        UserDefaults.standard.removeObject(forKey: onboardingVersionKey)
        UserDefaults.standard.removeObject(forKey: currentStepKey)

        for step in OnboardingStep.allCases {
            UserDefaults.standard.removeObject(forKey: stepCompletedPrefix + "\(step.rawValue)")
        }

        forceShowOnboarding = false
        currentStep = .welcome
    }

    func showFromSettings() {
        forceShowOnboarding = true
        if hasCompletedOnboarding {
            currentStep = .welcome
        }
    }
}

// MARK: - Onboarding Window Controller

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

// MARK: - Window Delegate

private final class OnboardingWindowDelegate: NSObject, NSWindowDelegate {
    let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_: Notification) {
        onClose()
    }
}
