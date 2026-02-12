import Foundation

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
