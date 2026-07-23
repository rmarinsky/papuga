import SwiftUI

struct PermissionStepView: View {
    let permission: OnboardingPermission
    let onContinue: () -> Void
    let onSkip: () -> Void

    @State private var coordinator: PermissionCoordinator
    @State private var permissionPollTask: Task<Void, Never>?
    @State private var advanceTask: Task<Void, Never>?
    @State private var didAdvance = false

    init(permission: OnboardingPermission, onContinue: @escaping () -> Void, onSkip: @escaping () -> Void) {
        self.permission = permission
        self.onContinue = onContinue
        self.onSkip = onSkip
        _coordinator = State(initialValue: PermissionCoordinator(permission: permission.permissionType))
    }

    var body: some View {
        VStack(spacing: 24) {
            ProgressDots(total: 4, current: permission.stepIndex + 1)
                .padding(.top, 30)

            Spacer()

            VStack(spacing: 20) {
                ZStack {
                    Circle()
                        .fill(coordinator.isGranted ? Color.green.opacity(0.1) : Color("BrandTintSoft"))
                        .frame(width: 80, height: 80)

                    if coordinator.isGranted {
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

                if !coordinator.isGranted {
                    WhyNeededView(permission: permission)
                }

                if coordinator.showsManualPath {
                    Text(coordinator.manualPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }

            Spacer()

            VStack(spacing: 12) {
                if coordinator.isGranted {
                    Button("Далі") {
                        advance(after: nil)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                } else {
                    Button(coordinator.primaryButtonTitle) {
                        requestPermission()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button("Зроблю пізніше") {
                        didAdvance = true
                        cancelTasks()
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
            coordinator.refresh()
            startPermissionPolling()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            coordinator.refresh()
            advanceIfGranted()
        }
        .onDisappear {
            cancelTasks()
        }
    }

    private func requestPermission() {
        coordinator.performPrimaryAction()
        startPermissionPolling()
    }

    private func startPermissionPolling() {
        guard permissionPollTask == nil else { return }
        permissionPollTask = Task { @MainActor in
            while !Task.isCancelled {
                coordinator.refresh()
                if coordinator.isGranted {
                    advanceIfGranted()
                    return
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func advanceIfGranted() {
        guard coordinator.isGranted else { return }
        advance(after: .milliseconds(300))
    }

    private func advance(after delay: Duration?) {
        guard !didAdvance else { return }
        didAdvance = true
        permissionPollTask?.cancel()
        permissionPollTask = nil
        guard let delay else {
            onContinue()
            return
        }
        bringWindowToFront()
        advanceTask = Task { @MainActor in
            try? await Task.sleep(for: delay)
            if !Task.isCancelled {
                onContinue()
            }
        }
    }

    private func cancelTasks() {
        permissionPollTask?.cancel()
        permissionPollTask = nil
        advanceTask?.cancel()
        advanceTask = nil
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
