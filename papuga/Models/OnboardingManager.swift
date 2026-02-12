import Foundation

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
