import SwiftUI

struct PermissionRow: View {
    let icon: String
    let title: String
    let description: String
    @Binding var isGranted: Bool
    let permissionType: PermissionType
    @State private var coordinator: PermissionCoordinator

    init(
        icon: String,
        title: String,
        description: String,
        isGranted: Binding<Bool>,
        permissionType: PermissionType
    ) {
        self.icon = icon
        self.title = title
        self.description = description
        _isGranted = isGranted
        self.permissionType = permissionType
        _coordinator = State(initialValue: PermissionCoordinator(permission: permissionType))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
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
                    Button(coordinator.primaryButtonTitle) {
                        coordinator.performPrimaryAction()
                        syncGrantedState()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            if coordinator.showsManualPath {
                Text(coordinator.manualPath)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.leading, 44)
            }
        }
        .padding(.vertical, 4)
        .onAppear {
            coordinator.refresh()
            syncGrantedState()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            coordinator.refresh()
            syncGrantedState()
        }
    }

    private func syncGrantedState() {
        isGranted = coordinator.isGranted
    }
}
