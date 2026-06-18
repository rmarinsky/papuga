import AppKit
import SwiftUI

struct MenuBarIconView: View {
    @State private var angle: Double = 0

    private static let baseImage: NSImage = {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            .applying(.preferringMonochrome())
        if let sym = NSImage(systemSymbolName: "bird.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(config) {
            let s = sym.size
            sym.draw(in: NSRect(x: (size.width - s.width) / 2, y: (size.height - s.height) / 2, width: s.width, height: s.height))
        }
        image.isTemplate = true
        return image
    }()

    var body: some View {
        Image(nsImage: Self.baseImage)
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
