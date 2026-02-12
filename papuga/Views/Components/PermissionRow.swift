import SwiftUI

struct PermissionRow: View {
    let icon: String
    let title: String
    let description: String
    @Binding var isGranted: Bool
    let permissionType: PermissionType
    @State private var isChecking = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(isGranted ? .green : .orange)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if isGranted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.title3)
            } else {
                Button(isChecking ? "Перевіряю..." : "Перевірити") {
                    Task {
                        await checkAndUpdatePermission()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isChecking)
            }
        }
        .padding(.vertical, 4)
    }

    @MainActor
    private func checkAndUpdatePermission() async {
        if isChecking {
            return
        }

        isChecking = true
        defer { isChecking = false }

        if currentPermissionStatus() {
            isGranted = true
            return
        }

        let requestSucceeded = requestPermission()
        if requestSucceeded {
            isGranted = true
            return
        }

        for _ in 0..<6 {
            try? await Task.sleep(for: .milliseconds(500))
            if currentPermissionStatus() {
                isGranted = true
                return
            }
        }

        // If prompt did not appear or permission was previously denied,
        // take user directly to the correct Privacy pane.
        PermissionManager.shared.openSystemSettingsForPermission(permissionType)

        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(500))
            if currentPermissionStatus() {
                isGranted = true
                return
            }
        }

        isGranted = false
    }

    @MainActor
    private func currentPermissionStatus() -> Bool {
        switch permissionType {
        case .accessibility:
            return PermissionManager.shared.checkAccessibilityPermission()
        case .inputMonitoring:
            return PermissionManager.shared.checkInputMonitoringPermission()
        }
    }

    @MainActor
    private func requestPermission() -> Bool {
        switch permissionType {
        case .accessibility:
            return PermissionManager.shared.requestAccessibilityPermission()
        case .inputMonitoring:
            return PermissionManager.shared.requestInputMonitoringPermission()
        }
    }
}
