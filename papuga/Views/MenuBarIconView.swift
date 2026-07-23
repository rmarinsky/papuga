import SwiftUI

struct MenuBarIconView: View {
    @State private var angle: Double = 0

    var body: some View {
        Text("🦜")
            .font(.system(size: 15))
            .frame(width: 18, height: 18)
            .rotationEffect(.degrees(angle))
            .onReceive(NotificationCenter.default.publisher(for: .textReplacementDidComplete).receive(on: RunLoop.main)) { _ in
                startSpinAnimation()
            }
            .accessibilityLabel("Papuga")
    }

    private func startSpinAnimation() {
        angle = 0
        withAnimation(.linear(duration: 0.4)) {
            angle = -360
        }
    }
}
