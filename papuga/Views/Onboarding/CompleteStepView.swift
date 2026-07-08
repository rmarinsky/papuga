import SwiftUI

struct CompleteStepView: View {
    let onFinish: () -> Void
    let onDefer: () -> Void

    @State private var showConfetti = false
    @State private var permissionStatus = PermissionManager.PermissionStatus()

    private var canComplete: Bool {
        PermissionCompletionPolicy.canComplete(permissionStatus)
    }

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 12)

            ZStack {
                Circle()
                    .fill((canComplete ? Color.green : Color.orange).opacity(0.1))
                    .frame(width: 100, height: 100)

                Image(systemName: canComplete ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 50))
                    .foregroundColor(canComplete ? .green : .orange)
            }
            .scaleEffect(showConfetti ? 1 : 0.5)
            .opacity(showConfetti ? 1 : 0)

            VStack(spacing: 12) {
                Text(canComplete ? "Все готово!" : "Налаштування не завершено")
                    .font(.system(size: 28, weight: .bold, design: .rounded))

                Text(canComplete
                     ? "Виділи текст і натисни Opt+Shift, Cmd+Shift або Ctrl+Shift двічі\nдля перемикання розкладки."
                     : "Для роботи Papuga потрібні Спеціальні можливості та Моніторинг введення.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 12) {
                if canComplete {
                    FeatureRow(icon: "keyboard", text: "Opt+Shift × 2 — перемикання вперед")
                    FeatureRow(icon: "command", text: "Cmd+Shift × 2 — перемикання вперед")
                    FeatureRow(icon: "keyboard", text: "Ctrl+Shift × 2 — перемикання вперед")
                    FeatureRow(icon: "menubar.rectangle", text: "Іконка в меню-барі для швидкого доступу")
                } else {
                    FeatureRow(
                        icon: permissionStatus.accessibility ? "checkmark.circle.fill" : "xmark.circle",
                        text: "Спеціальні можливості"
                    )
                    FeatureRow(
                        icon: permissionStatus.inputMonitoring ? "checkmark.circle.fill" : "xmark.circle",
                        text: "Моніторинг введення"
                    )
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 4)

            if !canComplete {
                Button("Відкрити потрібні налаштування") {
                    openMissingPermissionSettings()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            if canComplete {
                Button("Почати роботу", action: onFinish)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.top, 8)
                    .padding(.bottom, 20)
            } else {
                Button("Завершити пізніше", action: onDefer)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .padding(.top, 8)
                    .padding(.bottom, 20)
            }
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            refreshPermissions()
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                showConfetti = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
    }

    private func refreshPermissions() {
        PermissionManager.shared.refreshStatus()
        permissionStatus = PermissionManager.shared.status
    }

    private func openMissingPermissionSettings() {
        if !permissionStatus.accessibility {
            PermissionManager.shared.openSystemSettingsForPermission(.accessibility)
        } else if !permissionStatus.inputMonitoring {
            PermissionManager.shared.openSystemSettingsForPermission(.inputMonitoring)
        }
    }
}
