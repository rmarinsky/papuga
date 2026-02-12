import ApplicationServices
import CoreGraphics
import SwiftUI

// MARK: - Onboarding Permission

enum OnboardingPermission {
    case accessibility
    case inputMonitoring

    var title: String {
        switch self {
        case .accessibility: return "Спеціальні можливості"
        case .inputMonitoring: return "Моніторинг введення"
        }
    }

    var description: String {
        switch self {
        case .accessibility:
            return "Потрібен для симуляції комбінацій клавіш Cmd+C та Cmd+V для копіювання та вставки тексту."
        case .inputMonitoring:
            return "Потрібен для відстеження комбінацій клавіш перемикання розкладки."
        }
    }

    var icon: String {
        switch self {
        case .accessibility: return "accessibility"
        case .inputMonitoring: return "keyboard"
        }
    }

    var stepIndex: Int {
        switch self {
        case .accessibility: return 0
        case .inputMonitoring: return 1
        }
    }
}

// MARK: - Container

struct OnboardingContainerView: View {
    let onComplete: () -> Void

    @State private var currentStep: OnboardingStep = OnboardingManager.shared.currentStep

    var body: some View {
        Group {
            switch currentStep {
            case .welcome:
                WelcomeStepView(onContinue: { goToStep(.accessibilityPermission) })

            case .accessibilityPermission:
                PermissionStepView(
                    permission: .accessibility,
                    onContinue: { goToStep(.inputMonitoringPermission) },
                    onSkip: { goToStep(.inputMonitoringPermission) }
                )

            case .inputMonitoringPermission:
                PermissionStepView(
                    permission: .inputMonitoring,
                    onContinue: { goToStep(.complete) },
                    onSkip: { goToStep(.complete) }
                )

            case .complete:
                CompleteStepView(onFinish: onComplete)
            }
        }
        .frame(minWidth: 520, minHeight: 560)
        .transition(.asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        ))
        .id(currentStep)
        .onAppear {
            currentStep = OnboardingManager.shared.currentStep
        }
    }

    private func goToStep(_ step: OnboardingStep) {
        OnboardingManager.shared.completeStep(currentStep)
        withAnimation(.easeInOut(duration: 0.3)) {
            currentStep = step
        }
    }
}

// MARK: - Welcome Step

private struct WelcomeStepView: View {
    let onContinue: () -> Void

    @State private var showContent = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 24) {
                    Image(systemName: "keyboard")
                        .font(.system(size: 48))
                        .foregroundStyle(Color.accentColor)
                        .padding(.top, 20)

                    VStack(spacing: 10) {
                        Text("Ласкаво просимо до Papuga")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .minimumScaleFactor(0.85)

                        Text("Перемикач розкладки клавіатури для macOS")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)

                        Text("Економимо мільйони секунд на рік, які краде поламана розкладка.")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.accentColor)
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                    }

                    if showContent {
                        VStack(alignment: .leading, spacing: 12) {
                            FeatureRow(icon: "arrow.left.arrow.right", text: "Конвертуйте вже набраний текст між розкладками")
                            FeatureRow(icon: "command", text: "Виділіть текст і натисніть Opt+Shift, Cmd+Shift або Ctrl+Shift двічі")
                            FeatureRow(icon: "globe", text: "Підтримка будь-яких системних розкладок")
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity)
            }

            Divider()
                .padding(.horizontal, 20)

            VStack(spacing: 10) {
                Button("Почати налаштування") {
                    onContinue()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: 320)

                Text("Займе менше хвилини")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 16)
            .padding(.bottom, 24)
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial)
        }
        .background(
            LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.14),
                    Color.clear
                ],
                startPoint: .top,
                endPoint: .center
            )
        )
        .onAppear {
            withAnimation(.easeOut(duration: 0.4).delay(0.2)) {
                showContent = true
            }
        }
    }
}

private struct FeatureRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24, height: 24)
                .padding(8)
                .background(Color.accentColor.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            Text(text)
                .font(.callout.weight(.medium))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.9))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                )
        )
    }
}

// MARK: - Permission Step

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
                        .fill(isGranted ? Color.green.opacity(0.1) : Color.accentColor.opacity(0.1))
                        .frame(width: 80, height: 80)

                    if isGranted {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 40))
                            .foregroundColor(.green)
                    } else {
                        Image(systemName: permission.icon)
                            .font(.system(size: 32))
                            .foregroundColor(.accentColor)
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
            isGranted = AXIsProcessTrusted()
        case .inputMonitoring:
            isGranted = CGPreflightListenEventAccess()
        }
    }

    private func requestPermission() {
        isRequesting = true
        permissionPollTask?.cancel()
        permissionPollTask = nil

        switch permission {
        case .accessibility:
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)

        case .inputMonitoring:
            CGRequestListenEventAccess()
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

// MARK: - Complete Step

private struct CompleteStepView: View {
    let onFinish: () -> Void

    @State private var showConfetti = false

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 12)

            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.1))
                    .frame(width: 100, height: 100)

                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 50))
                    .foregroundColor(.green)
            }
            .scaleEffect(showConfetti ? 1 : 0.5)
            .opacity(showConfetti ? 1 : 0)

            VStack(spacing: 12) {
                Text("Все готово!")
                    .font(.system(size: 28, weight: .bold, design: .rounded))

                Text("Виділіть текст та натисніть Opt+Shift, Cmd+Shift або Ctrl+Shift двічі\nдля перемикання розкладки.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 12) {
                FeatureRow(icon: "keyboard", text: "Opt+Shift × 2 — перемикання вперед")
                FeatureRow(icon: "command", text: "Cmd+Shift × 2 — перемикання вперед")
                FeatureRow(icon: "keyboard", text: "Ctrl+Shift × 2 — перемикання вперед")
                FeatureRow(icon: "menubar.rectangle", text: "Іконка в меню-барі для швидкого доступу")
            }
            .padding(.horizontal, 24)
            .padding(.top, 4)

            Button("Почати роботу") {
                onFinish()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 8)
            .padding(.bottom, 20)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                showConfetti = true
            }
        }
    }
}

// MARK: - Progress Dots

struct ProgressDots: View {
    let total: Int
    let current: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<total, id: \.self) { index in
                Circle()
                    .fill(index < current ? Color.accentColor : Color.gray.opacity(0.3))
                    .frame(width: 8, height: 8)
            }
        }
    }
}
