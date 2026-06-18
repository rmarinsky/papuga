import AppKit
import SwiftUI
import Defaults
import LaunchAtLogin

struct GeneralTab: View {
    @Default(.showMenuBarIcon) private var showMenuBarIcon
    @Default(.clipboardHistoryRetention) private var clipboardHistoryRetention
    @Default(.clipboardMenuTimeRange) private var clipboardMenuTimeRange
    @Default(.clipboardMenuItemLimit) private var clipboardMenuItemLimit
    @Default(.replacementHistoryEnabled) private var replacementHistoryEnabled
    @Default(.replacementHistoryRetention) private var replacementHistoryRetention
    @Default(.openHistoryOnAppLaunch) private var openHistoryOnAppLaunch
    @State private var accessibilityGranted = false
    @State private var inputMonitoringGranted = false
    @State private var showingClearHistoryConfirmation = false

    var body: some View {
        Form {
            Section("Сервіс") {
                LaunchAtLogin.Toggle("Запускати при вході в систему")
                Toggle("Показувати іконку в меню-барі", isOn: $showMenuBarIcon)
            }

            Section("Копіопасти") {
                Picker("Зберігати історію", selection: $clipboardHistoryRetention) {
                    ForEach(ClipboardHistoryRetentionPreset.allCases, id: \.rawValue) { preset in
                        Text(preset.title).tag(preset.rawValue)
                    }
                }
                .pickerStyle(.menu)

                Picker("Показувати в меню за період", selection: $clipboardMenuTimeRange) {
                    ForEach(ClipboardHistoryRetentionPreset.allCases, id: \.rawValue) { preset in
                        Text(preset.title).tag(preset.rawValue)
                    }
                }
                .pickerStyle(.menu)

                Picker("К-сть пунктів у меню", selection: $clipboardMenuItemLimit) {
                    ForEach(ClipboardHistoryMenuItemLimitPreset.allCases, id: \.rawValue) { preset in
                        Text(preset.title).tag(preset.rawValue)
                    }
                }
                .pickerStyle(.menu)
            }

            Section("Історія замін") {
                Toggle("Зберігати історію замін", isOn: $replacementHistoryEnabled)

                Picker("Зберігати", selection: $replacementHistoryRetention) {
                    ForEach(ReplacementHistoryRetention.allCases, id: \.rawValue) { preset in
                        Text(preset.title).tag(preset.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .disabled(!replacementHistoryEnabled)

                Toggle("Відкривати вікно «Історія» при запуску", isOn: $openHistoryOnAppLaunch)

                Button(role: .destructive) {
                    showingClearHistoryConfirmation = true
                } label: {
                    Label("Очистити історію замін…", systemImage: "trash")
                }
                .confirmationDialog(
                    "Очистити історію замін?",
                    isPresented: $showingClearHistoryConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Очистити", role: .destructive) {
                        ReplacementHistoryStore.shared.clearAll()
                    }
                    Button("Скасувати", role: .cancel) {}
                } message: {
                    Text("Усі записи про ручні перемикання та події AutoFix буде видалено.")
                }
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
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            checkPermissionsPassive()
        }
    }

    private func checkPermissionsPassive() {
        accessibilityGranted = PermissionManager.shared.checkAccessibilityPermission()
        inputMonitoringGranted = PermissionManager.shared.checkInputMonitoringPermission()
    }
}
