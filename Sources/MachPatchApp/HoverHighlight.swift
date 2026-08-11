import SwiftUI

private struct HoverHighlightModifier: ViewModifier {
    let isActive: Bool
    let showsIdleChrome: Bool
    let horizontalOutset: CGFloat
    let verticalOutset: CGFloat
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
                    .opacity(isActive ? 1 : showsIdleChrome ? 0.57 : 0)
                    .padding(.horizontal, -horizontalOutset)
                    .padding(.vertical, -verticalOutset)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.42), lineWidth: 1)
                    .opacity(
                        showsIdleChrome ? (isActive ? 1 : 0.57) : 0
                    )
                    .padding(.horizontal, -horizontalOutset)
                    .padding(.vertical, -verticalOutset)
            }
            .animation(.easeOut(duration: 0.1), value: isActive)
    }
}

extension View {
    func hoverHighlight(
        isActive: Bool,
        showsIdleChrome: Bool = false,
        horizontalOutset: CGFloat = 0,
        verticalOutset: CGFloat = 0,
        cornerRadius: CGFloat = 8
    ) -> some View {
        modifier(
            HoverHighlightModifier(
                isActive: isActive,
                showsIdleChrome: showsIdleChrome,
                horizontalOutset: horizontalOutset,
                verticalOutset: verticalOutset,
                cornerRadius: cornerRadius
            )
        )
    }
}
