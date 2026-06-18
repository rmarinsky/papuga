import SwiftUI

enum InstantTooltipPlacement {
    case above
    case below
}

struct InstantTooltipModifier: ViewModifier {
    let text: String
    var placement: InstantTooltipPlacement = .above

    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .onHover { isHovering = $0 }
            .overlay(alignment: placement == .above ? .top : .bottom) {
                if isHovering {
                    Text(text)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: true)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(.black.opacity(0.9))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(.white.opacity(0.18), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.22), radius: 8, x: 0, y: 4)
                        .offset(y: placement == .above ? -29 : 29)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                        .zIndex(1000)
                }
            }
            .animation(.easeOut(duration: 0.06), value: isHovering)
    }
}

extension View {
    func instantTooltip(
        _ text: String,
        placement: InstantTooltipPlacement = .above
    ) -> some View {
        modifier(InstantTooltipModifier(text: text, placement: placement))
    }
}
