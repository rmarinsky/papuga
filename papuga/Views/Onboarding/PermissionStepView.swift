import SwiftUI

struct PermissionStepView: View {
    let permission: OnboardingPermission
    let onContinue: () -> Void
    let onSkip: () -> Void

    @State private var isGranted = false
    @State private var isRequesting = false
    @State private var permissionPollTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 24) {
            ProgressDots(total: 4, current: permission.stepIndex + 1)
                .padding(.top, 30)

            Spacer()

            VStack(spacing: 20) {
                ZStack {
                    Circle()
                        .fill(isGranted ? Color.green.opacity(0.1) : Color("BrandTintSoft"))
                        .frame(width: 80, height: 80)

                    if isGranted {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 40))
                            .foregroundColor(.green)
                    } else {
                        Image(systemName: permission.icon)
                            .font(.system(size: 32))
                            .foregroundStyle(Color("BrandAccentDeep"))
                    }
                }

                VStack(spacing: 10) {
                    Text(permission.title)
                        .font(.title2)
                        .fontWeight(.bold)

                    Text(permission.description)
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }

                if !isGranted {
                    WhyNeededView(permission: permission)
                }
            }

            Spacer()

            VStack(spacing: 12) {
                if isGranted {
                    Button("Далі") {
                        onContinue()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                } else {
                    Button(isRequesting ? "Запит..." : "Надати дозвіл") {
                        requestPermission()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isRequesting)

                    Button("Зроблю пізніше") {
                        permissionPollTask?.cancel()
                        permissionPollTask = nil
                        onSkip()
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(.secondary)
                }
            }
            .padding(.bottom, 30)
        }
        .padding(.horizontal, 20)
        .onAppear {
            checkPermission()
        }
        .onDisappear {
            permissionPollTask?.cancel()
            permissionPollTask = nil
        }
    }

    private func checkPermission() {
        switch permission {
        case .accessibility:
            isGranted = PermissionManager.shared.checkAccessibilityPermission()
        case .inputMonitoring:
            isGranted = PermissionManager.shared.checkInputMonitoringPermission()
        }
    }

    private func requestPermission() {
        isRequesting = true
        permissionPollTask?.cancel()
        permissionPollTask = nil

        switch permission {
        case .accessibility:
            PermissionManager.shared.requestAccessibilityPermission()
        case .inputMonitoring:
            PermissionManager.shared.requestInputMonitoringPermission()
        }

        isRequesting = false
        startPermissionPolling()
    }

    private func startPermissionPolling() {
        permissionPollTask = Task { @MainActor in
            while !Task.isCancelled {
                checkPermission()
                if isGranted {
                    bringWindowToFront()
                    try? await Task.sleep(for: .milliseconds(300))
                    if !Task.isCancelled {
                        onContinue()
                    }
                    return
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func bringWindowToFront() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows {
            if window.title.contains("Papuga") {
                window.makeKeyAndOrderFront(nil)
                break
            }
        }
    }
}

private struct WhyNeededView: View {
    let permission: OnboardingPermission

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundColor(.secondary)

            Text(whyText)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var whyText: String {
        switch permission {
        case .accessibility:
            return "Без цього дозволу копіювання та вставка тексту не працюватимуть."
        case .inputMonitoring:
            return "Без цього дозволу гарячі клавіші не відстежуватимуться."
        }
    }
}
