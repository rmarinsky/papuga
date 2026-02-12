import SwiftUI
import Defaults
import LaunchAtLogin

struct GeneralTab: View {
    @Default(.showMenuBarIcon) private var showMenuBarIcon
    @State private var accessibilityGranted = false
    @State private var inputMonitoringGranted = false

    var body: some View {
        Form {
            Section("Сервіс") {
                LaunchAtLogin.Toggle("Запускати при вході в систему")
                Toggle("Показувати іконку в меню-барі", isOn: $showMenuBarIcon)
            }

            Section("Дозволи") {
                PermissionRow(
                    icon: "accessibility",
                    title: "Спеціальні можливості",
                    description: "Симуляція Cmd+C та Cmd+V",
                    isGranted: $accessibilityGranted,
                    permissionType: .accessibility
                )
                PermissionRow(
                    icon: "keyboard",
                    title: "Моніторинг введення",
                    description: "Відстеження гарячих клавіш",
                    isGranted: $inputMonitoringGranted,
                    permissionType: .inputMonitoring
                )
            }
        }
        .formStyle(.grouped)
        .task {
            checkPermissionsPassive()
        }
    }

    private func checkPermissionsPassive() {
        accessibilityGranted = PermissionManager.shared.checkAccessibilityPermission()
        inputMonitoringGranted = PermissionManager.shared.checkInputMonitoringPermission()
    }
}
