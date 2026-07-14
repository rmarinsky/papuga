import SwiftUI

struct OnboardingContainerView: View {
    let onComplete: () -> Void
    let onDefer: () -> Void

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
                CompleteStepView(onFinish: onComplete, onDefer: onDefer)
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
