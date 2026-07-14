import Foundation

enum OnboardingPermission {
    case accessibility
    case inputMonitoring

    var title: String {
        switch self {
        case .accessibility: return "Спеціальні можливості"
        case .inputMonitoring: return "Моніторинг введення"
        }
    }

    var description: String {
        switch self {
        case .accessibility:
            return "Потрібен для симуляції комбінацій клавіш Cmd+C та Cmd+V для копіювання та вставки тексту."
        case .inputMonitoring:
            return "Потрібен для відстеження комбінацій клавіш перемикання розкладки."
        }
    }

    var icon: String {
        switch self {
        case .accessibility: return "accessibility"
        case .inputMonitoring: return "keyboard"
        }
    }

    var stepIndex: Int {
        switch self {
        case .accessibility: return 0
        case .inputMonitoring: return 1
        }
    }

    var permissionType: PermissionType {
        switch self {
        case .accessibility: return .accessibility
        case .inputMonitoring: return .inputMonitoring
        }
    }
}
