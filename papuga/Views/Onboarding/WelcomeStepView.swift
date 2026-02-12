import SwiftUI

struct WelcomeStepView: View {
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
