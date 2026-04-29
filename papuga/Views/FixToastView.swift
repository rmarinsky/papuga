import SwiftUI

/// Floating "papuga did a flip" toast that appears near the cursor for ~2 s after
/// an auto-fix. Click it to undo the fix and add the original word to the allowlist
/// so it won't be auto-fixed again.
struct FixToastView: View {
    let onClick: () -> Void

    @State private var spin: Double = 0
    @State private var scale: CGFloat = 0.4
    @State private var opacity: Double = 0
    @State private var hover = false

    var body: some View {
        Button(action: onClick) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.25), radius: 8, x: 0, y: 3)
                Text("🦜")
                    .font(.system(size: 38))
                    .rotation3DEffect(.degrees(spin), axis: (x: 1, y: 0, z: 0))
                    .scaleEffect(hover ? 1.15 : 1.0)
                    .animation(.spring(response: 0.25, dampingFraction: 0.5), value: hover)
            }
            .frame(width: 70, height: 70)
            .scaleEffect(scale)
            .opacity(opacity)
            .overlay(alignment: .bottom) {
                Text("undo")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
                    .opacity(hover ? 1 : 0.5)
            }
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .onAppear {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.55)) {
                scale = 1.0
                opacity = 1.0
            }
            // Two full somersaults over 0.8s
            withAnimation(.easeInOut(duration: 0.8)) {
                spin = 720
            }
        }
    }
}
