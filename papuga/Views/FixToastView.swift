import SwiftUI

/// Floating "papuga did a flip" toast that appears near the cursor for ~2 s after
/// an auto-fix. Clicking it only undoes that occurrence; persistent ignoring is a
/// separate, explicitly labelled proposal action.
struct FixToastView: View {
    let onClick: (() -> Void)?

    @State private var flip = PapugaFlipAnimation()
    @State private var scale: CGFloat = 0.4
    @State private var opacity: Double = 0
    @State private var hover = false

    var body: some View {
        Group {
            if let onClick {
                Button(action: onClick) {
                    content
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("autofix-undo-action")
                .onHover { hover = $0 }
            } else {
                content
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.65)) {
                scale = 1.0
                opacity = 1.0
            }
            // Full 360° spin around the centre of the block.
            withAnimation(.easeOut(duration: 0.6)) {
                flip.trigger()
            }
        }
    }

    private var content: some View {
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

            Text(PapugaFlipAnimation.emoji)
                .font(.system(size: 24))
                .rotationEffect(.degrees(flip.degrees))
                .scaleEffect(hover ? 1.18 : 1.0)
                .animation(.spring(response: 0.25, dampingFraction: 0.5), value: hover)
        }
        .frame(width: 50, height: 50)
        .scaleEffect(scale)
        .opacity(opacity)
    }
}

/// Passive catch-up chip for a fix the user typed past. Unlike the proposal
/// panel it never listens to the keyboard: it outlives continued typing and is
/// resolved only by mouse (click = apply, × = close) or by its own time-to-live,
/// shown draining along the bottom edge.
struct DeferredFixChipView: View {
    let original: String
    let candidate: String
    /// Panel width, pinned onto the content. Without an explicit size the
    /// hosting view asks its window to resize to fit — and doing that from
    /// inside a running animation re-enters AppKit's layout pass and throws
    /// (`_postWindowNeedsUpdateConstraints`), which aborted the app when the
    /// chip's drain animation ran out.
    let width: CGFloat
    let timeToLive: TimeInterval
    let onApply: () -> Void
    let onDismiss: () -> Void

    static let height: CGFloat = 30

    @State private var remaining: CGFloat = 1
    @State private var hover = false

    var body: some View {
        Button(action: onApply) {
            HStack(spacing: 6) {
                Text(PapugaFlipAnimation.emoji)
                    .font(.system(size: 13))
                Text(original)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("→")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(candidate)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color("BrandAccentDeep"))
                    .lineLimit(1)
                Button(action: onDismiss) {
                    Text("×")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("autofix-chip-dismiss")
            }
            .padding(.horizontal, 11)
            .frame(width: width, height: Self.height)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                Capsule().strokeBorder(
                    Color("BrandAccent").opacity(hover ? 0.75 : 0.28),
                    lineWidth: hover ? 1.2 : 0.8
                )
            )
            .overlay(alignment: .bottom) {
                // scaleEffect, not an animated frame width: a transform is a
                // render-time effect, so draining the bar never invalidates
                // layout and never asks the panel to resize mid-animation.
                Capsule()
                    .fill(Color("BrandAccentDeep").opacity(0.85))
                    .frame(width: max(0, width - 20), height: 2)
                    .scaleEffect(x: remaining, y: 1, anchor: .leading)
                    .padding(.bottom, 2)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityIdentifier("autofix-chip-apply")
        .onAppear {
            withAnimation(.linear(duration: timeToLive)) {
                remaining = 0
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
