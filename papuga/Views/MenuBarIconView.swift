import AppKit
import SwiftUI

struct MenuBarIconView: View {
    @State private var frameIndex = 0
    @State private var animationTask: Task<Void, Never>?

    private static let frames = RotatingIconFrames.build()
    private static let frameDelayMilliseconds = 10

    var body: some View {
        Image(nsImage: MenuBarIconView.frames[frameIndex])
            .onReceive(NotificationCenter.default.publisher(for: .textReplacementDidComplete).receive(on: RunLoop.main)) { _ in
                AppLogger.pre(AppLogger.ui, "Received textReplacementDidComplete notification")
                startSpinAnimation()
            }
            .accessibilityLabel("Papuga")
            .onDisappear {
                animationTask?.cancel()
                animationTask = nil
                frameIndex = 0
            }
    }

    private func startSpinAnimation() {
        AppLogger.pre(AppLogger.ui, "startSpinAnimation()")
        animationTask?.cancel()

        animationTask = Task { @MainActor in
            AppLogger.action(AppLogger.ui, "Starting menu bar icon frame animation")

            for index in MenuBarIconView.frames.indices {
                if Task.isCancelled {
                    AppLogger.warn(AppLogger.ui, "Menu bar icon animation cancelled")
                    return
                }

                frameIndex = index
                try? await Task.sleep(for: .milliseconds(MenuBarIconView.frameDelayMilliseconds))
            }

            frameIndex = 0
            AppLogger.post(AppLogger.ui, "Menu bar icon animation completed")
            animationTask = nil
        }
    }
}

private enum RotatingIconFrames {
    static func build() -> [NSImage] {
        let frameCount = 40
        return (0..<frameCount).map { index in
            let phase = CGFloat(index) / CGFloat(frameCount - 1)
            let angle = -phase * 360
            return renderFrame(angle: angle)
        }
    }

    private static func renderFrame(angle: CGFloat) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)

        image.lockFocus()
        defer { image.unlockFocus() }

        guard let context = NSGraphicsContext.current?.cgContext else {
            return image
        }

        context.translateBy(x: size.width / 2, y: size.height / 2)
        context.rotate(by: angle * .pi / 180)

        let icon = "🦜" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14)
        ]
        let textSize = icon.size(withAttributes: attributes)
        let drawRect = CGRect(
            x: -textSize.width / 2,
            y: -textSize.height / 2,
            width: textSize.width,
            height: textSize.height
        )

        icon.draw(in: drawRect, withAttributes: attributes)
        return image
    }
}
