import SwiftUI

struct PapugaFlipAnimation: Equatable {
    static let emoji = "🦜"
    private(set) var degrees: Double = 0

    mutating func trigger() {
        degrees -= 360
    }
}

struct MenuBarIconView: View {
    @State private var flip = PapugaFlipAnimation()

    var body: some View {
        Text(PapugaFlipAnimation.emoji)
            .font(.system(size: 15))
            .frame(width: 18, height: 18)
            .rotationEffect(.degrees(flip.degrees))
            .onReceive(NotificationCenter.default.publisher(for: .textReplacementDidComplete).receive(on: RunLoop.main)) { _ in
                startSpinAnimation()
            }
            .accessibilityLabel("Papuga")
    }

    private func startSpinAnimation() {
        withAnimation(.linear(duration: 0.4)) {
            flip.trigger()
        }
    }
}
