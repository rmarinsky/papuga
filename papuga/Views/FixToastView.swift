import SwiftUI

/// Floating "papuga did a flip" toast that appears near the cursor for ~2 s after
/// an auto-fix. Clicking it only undoes that occurrence; persistent ignoring is a
/// separate, explicitly labelled proposal action.
struct FixToastView: View {
    let onClick: () -> Void

    @State private var spin: Double = 0
    @State private var scale: CGFloat = 0.4
    @State private var opacity: Double = 0
    @State private var hover = false

    var body: some View {
        Button(action: onClick) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        .white.opacity(0.55),
                                        .white.opacity(0.08),
                                        .white.opacity(0.35)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 0.8
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        .white.opacity(0.18),
                                        .clear,
                                        .white.opacity(0.05)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    )
                    .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 4)
                    .shadow(color: .white.opacity(0.15), radius: 1, x: 0, y: 0.5)
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(Color("BrandAccent").opacity(hover ? 0.75 : 0), lineWidth: 1.5)
                            .animation(.easeInOut(duration: 0.15), value: hover)
                    )

                Text("🦜")
                    .font(.system(size: 24))
                    .rotationEffect(.degrees(spin))
                    .scaleEffect(hover ? 1.18 : 1.0)
                    .animation(.spring(response: 0.25, dampingFraction: 0.5), value: hover)
            }
            .frame(width: 50, height: 50)
            .scaleEffect(scale)
            .opacity(opacity)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("autofix-undo-action")
        .onHover { hover = $0 }
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.65)) {
                scale = 1.0
                opacity = 1.0
            }
            // Full 360° spin around the centre of the block.
            withAnimation(.easeOut(duration: 0.6)) {
                spin = 360
            }
        }
    }
}

struct FixRecoveryView: View {
    let title: String
    let onClick: () -> Void

    var body: some View {
        Button(action: onClick) {
            Label(title, systemImage: "arrow.uturn.backward.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color("BrandAccentDeep"))
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.28), lineWidth: 0.8))
                .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("autofix-recovery-action")
    }
}
