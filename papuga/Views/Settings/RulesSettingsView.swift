import AppKit
import Defaults
import SwiftUI

struct RulesSettingsView: View {
    @Default(.autoFixEnabled) private var autoFixEnabled
    @State private var accessibilityGranted = false
    @State private var inputMonitoringGranted = false

    var body: some View {
        VStack(spacing: 0) {
            runtimeStatusBanner
            AutoFixTab()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task {
            refreshPermissions()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
    }

    private var runtimeReady: Bool {
        autoFixEnabled && accessibilityGranted && inputMonitoringGranted
    }

    private var runtimeStatusBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: runtimeReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(runtimeReady ? Color("BrandAccentDeep") : .orange)

                VStack(alignment: .leading, spacing: 2) {
                    Text(runtimeReady ? "Правила активні" : "Правила зараз не спрацюють")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Для власних правил потрібні автозаміна, Спеціальні можливості та Моніторинг введення.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Оновити") {
                    refreshPermissions()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            HStack(spacing: 8) {
                requirementPill(title: "Автозаміна", isReady: autoFixEnabled) {
                    autoFixEnabled = true
                }
                requirementPill(title: "Спеціальні можливості", isReady: accessibilityGranted) {
                    PermissionManager.shared.openSystemSettingsForPermission(.accessibility)
                }
                requirementPill(title: "Моніторинг введення", isReady: inputMonitoringGranted) {
                    PermissionManager.shared.openSystemSettingsForPermission(.inputMonitoring)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(runtimeReady ? Color("BrandTintSoft").opacity(0.5) : Color.orange.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(runtimeReady ? Color("BrandTintBorder") : Color.orange.opacity(0.28), lineWidth: 1)
                )
        )
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 2)
    }

    private func requirementPill(title: String, isReady: Bool, action: @escaping () -> Void) -> some View {
        let setupTitle = title == "Автозаміна" ? "автозаміну" : title
        return Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: isReady ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(isReady ? Color("BrandAccentDeep") : .orange)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.72))
                    .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
        .help(isReady ? "\(title): готово" : "Налаштувати \(setupTitle)")
    }

    private func refreshPermissions() {
        accessibilityGranted = PermissionManager.shared.checkAccessibilityPermission()
        inputMonitoringGranted = PermissionManager.shared.checkInputMonitoringPermission()
    }
}
