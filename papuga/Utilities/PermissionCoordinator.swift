import Foundation

enum PermissionSettingsOpenResult: Equatable {
    case permissionPane
    case privacyAndSecurity
    case failed
}

@MainActor
protocol PermissionClient: AnyObject {
    func isGranted(_ type: PermissionType) -> Bool
    @discardableResult func request(_ type: PermissionType) -> Bool
    @discardableResult func openSettings(
        _ type: PermissionType,
        preferGeneralPrivacy: Bool
    ) -> PermissionSettingsOpenResult
}

@MainActor
@Observable
final class PermissionCoordinator {
    let permission: PermissionType
    private let client: PermissionClient

    private(set) var isGranted = false
    private(set) var hasAttemptedRequest = false
    private(set) var hasOpenedSettings = false
    private(set) var showsManualPath = false

    convenience init(permission: PermissionType) {
        self.init(permission: permission, client: PermissionManager.shared)
    }

    init(permission: PermissionType, client: PermissionClient) {
        self.permission = permission
        self.client = client
        refresh()
    }

    var primaryButtonTitle: String {
        if hasAttemptedRequest {
            switch permission {
            case .accessibility:
                return "Відкрити «Спеціальні можливості»"
            case .inputMonitoring:
                return "Відкрити «Моніторинг введення»"
            }
        }
        return "Надати дозвіл"
    }

    var manualPath: String {
        switch permission {
        case .accessibility:
            return "Системні параметри → Приватність і безпека → Спеціальні можливості"
        case .inputMonitoring:
            return "Системні параметри → Приватність і безпека → Моніторинг введення"
        }
    }

    func refresh() {
        isGranted = client.isGranted(permission)
        if isGranted {
            showsManualPath = false
        }
    }

    func performPrimaryAction() {
        refresh()
        guard !isGranted else { return }

        if !hasAttemptedRequest {
            hasAttemptedRequest = true
            _ = client.request(permission)
            refresh()
            guard !isGranted else { return }
        }

        let result = client.openSettings(
            permission,
            preferGeneralPrivacy: hasOpenedSettings
        )
        hasOpenedSettings = true
        // `NSWorkspace.open` can report success even when System Settings lands
        // on the general privacy page. Keep the manual route visible after any
        // failed request so the user is never stranded by a nominally-successful link.
        showsManualPath = !isGranted || result != .permissionPane
        refresh()
    }
}

enum PermissionCompletionPolicy {
    static func canComplete(_ status: PermissionManager.PermissionStatus) -> Bool {
        status.allGranted
    }
}
