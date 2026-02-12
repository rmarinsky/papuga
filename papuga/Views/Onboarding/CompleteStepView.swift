import SwiftUI

struct CompleteStepView: View {
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
