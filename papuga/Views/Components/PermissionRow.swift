import ApplicationServices
import CoreGraphics
import SwiftUI

struct PermissionRow: View {
    let icon: String
    let title: String
    let description: String
    @Binding var isGranted: Bool
    let permissionType: PermissionType

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
                Button("Перевірити") {
                    Task {
                        await checkAndUpdatePermission()
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 4)
    }

    private func checkAndUpdatePermission() async {
        let granted: Bool

        switch permissionType {
        case .accessibility:
            if AXIsProcessTrusted() {
                granted = true
            } else {
                PermissionManager.shared.requestAccessibilityPermission()
                try? await Task.sleep(for: .milliseconds(500))
                await MainActor.run {
                    NSApp.activate(ignoringOtherApps: true)
                }
                try? await Task.sleep(for: .milliseconds(500))
                granted = AXIsProcessTrusted()
            }

        case .inputMonitoring:
            if CGPreflightListenEventAccess() {
                granted = true
            } else {
                PermissionManager.shared.requestInputMonitoringPermission()
                try? await Task.sleep(for: .milliseconds(500))
                await MainActor.run {
                    NSApp.activate(ignoringOtherApps: true)
                }
                try? await Task.sleep(for: .milliseconds(500))
                granted = CGPreflightListenEventAccess()
            }
        }

        await MainActor.run {
            isGranted = granted
        }
    }
}
