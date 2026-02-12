import AppKit
import ApplicationServices
import CoreGraphics

enum PermissionType {
    case accessibility
    case inputMonitoring
}

@MainActor
final class PermissionManager {
    static let shared = PermissionManager()

    // MARK: - Permission Status

    struct PermissionStatus: Sendable {
        var accessibility: Bool = false
        var inputMonitoring: Bool = false

        var allGranted: Bool {
            accessibility && inputMonitoring
        }
    }

    private(set) var status = PermissionStatus()

    private init() {}

    // MARK: - Check Permissions

    func checkAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    func checkInputMonitoringPermission() -> Bool {
        CGPreflightListenEventAccess()
    }

    // MARK: - Request Permissions

    func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    func requestInputMonitoringPermission() {
        CGRequestListenEventAccess()
    }

    // MARK: - Refresh

    func refreshStatus() {
        status.accessibility = checkAccessibilityPermission()
        status.inputMonitoring = checkInputMonitoringPermission()
    }

    // MARK: - Permission Alert

    func showPermissionAlert(for type: PermissionType) {
        Task {
            switch type {
            case .accessibility:
                if AXIsProcessTrusted() {
                    refreshStatus()
                    return
                }
                requestAccessibilityPermission()
                try? await Task.sleep(for: .seconds(1))
                refreshStatus()
                return

            case .inputMonitoring:
                if CGPreflightListenEventAccess() {
                    refreshStatus()
                    return
                }
                requestInputMonitoringPermission()
                try? await Task.sleep(for: .seconds(1))
                refreshStatus()
                return
            }
        }
    }

    func openSystemSettingsForPermission(_ type: PermissionType) {
        var urlString: String?

        switch type {
        case .accessibility:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .inputMonitoring:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        }

        if let urlString, let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Permission Prompt UI

    func showPermissionPrompt() async -> PermissionStatus {
        let alert = NSAlert()
        alert.messageText = "Papuga потребує дозволів"
        alert.alertStyle = .informational

        var message = "Для коректної роботи Papuga потребує наступні дозволи:\n\n"

        if !status.accessibility {
            message += "♿️ Спеціальні можливості (Обов'язково)\n   • Симуляція Cmd+C та Cmd+V\n\n"
        }

        if !status.inputMonitoring {
            message += "⌨️ Моніторинг введення (Обов'язково)\n   • Відстеження гарячих клавіш\n\n"
        }

        message += "Натисніть «Надати дозволи» щоб відкрити Системні налаштування."

        alert.informativeText = message
        alert.addButton(withTitle: "Надати дозволи")
        alert.addButton(withTitle: "Пізніше")

        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            return await openSystemSettings()
        }

        return status
    }

    private func openSystemSettings() async -> PermissionStatus {
        if !status.accessibility {
            openSystemSettingsForPermission(.accessibility)
        } else if !status.inputMonitoring {
            openSystemSettingsForPermission(.inputMonitoring)
        }

        try? await Task.sleep(for: .seconds(3))
        return await recheckPermissions()
    }

    private func recheckPermissions() async -> PermissionStatus {
        refreshStatus()

        if !status.allGranted {
            return await showPermissionFollowUp()
        }

        return status
    }

    private func showPermissionFollowUp() async -> PermissionStatus {
        let alert = NSAlert()
        alert.messageText = "Дозволи все ще потрібні"
        alert.informativeText = """
            Papuga все ще потребує деяких дозволів для коректної роботи. \
            Ви можете продовжити без них, але деякі функції не працюватимуть.

            Ви можете надати дозволи пізніше у Налаштуваннях.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Спробувати знову")
        alert.addButton(withTitle: "Продовжити")

        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            return await openSystemSettings()
        }

        return status
    }
}
