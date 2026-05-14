import SwiftUI

/// Floating "papuga did a flip" toast that appears near the cursor for ~2 s after
/// an auto-fix. Click it to undo the fix and add the original word to the allowlist
/// so it won't be auto-fixed again.
struct FixToastView: View {
    static let size = NSSize(width: 74, height: 74)

    let replacement: String?
    let onClick: () -> Void

    @State private var spin: Double = 0
    @State private var scale: CGFloat = 0.4
    @State private var opacity: Double = 0
    @State private var hover = false
    @State private var captionOpacity: Double = 0
    @State private var captionScale: CGFloat = 0.6

    private var undoTitle: String {
        Locale.current.language.languageCode?.identifier == "uk" ? "Відмінити" : "Undo"
    }

    var body: some View {
        Button(action: onClick) {
            VStack(spacing: 2) {
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

                    parrot
                }
                .frame(width: 50, height: 50)

                Text(undoTitle)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary.opacity(0.86))
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.ultraThinMaterial, in: Capsule())
                    .opacity(hover ? 1 : 0)
                    .offset(y: hover ? 0 : -4)
                    .animation(.easeOut(duration: 0.18), value: hover)
            }
            .frame(width: FixToastView.size.width, height: FixToastView.size.height)
            .scaleEffect(scale)
            .opacity(opacity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(undoLabel)
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
            withAnimation(.spring(response: 0.45, dampingFraction: 0.65).delay(0.18)) {
                captionOpacity = 1.0
                captionScale = 1.0
            }
        }
    }

    private var parrot: some View {
        ZStack {
            Text("🦜")
                .font(.system(size: 26))
                .rotationEffect(.degrees(spin))
                .scaleEffect(hover ? 1.18 : 1.0)
                .animation(.spring(response: 0.25, dampingFraction: 0.5), value: hover)

            if let replacement, !replacement.isEmpty {
                captionBubble(text: replacement)
                    .offset(x: 30, y: -18)
                    .scaleEffect(captionScale, anchor: .bottomLeading)
                    .opacity(captionOpacity)
                    .allowsHitTesting(false)
            }
        }
    }

    private func captionBubble(text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(.primary.opacity(0.92))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .frame(maxWidth: 80)
            .background(
                Capsule(style: .continuous).fill(.regularMaterial)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(.white.opacity(0.35), lineWidth: 0.6)
            )
            .shadow(color: .black.opacity(0.22), radius: 3, x: 0, y: 1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var undoLabel: String {
        if let replacement, !replacement.isEmpty {
            return "\(undoTitle) \(replacement)"
        }
        return undoTitle
    }
}
