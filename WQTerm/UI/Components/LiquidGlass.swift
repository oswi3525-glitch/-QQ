import SwiftUI

/// Phong cách "Liquid Glass" dùng chung cho toàn bộ WQTerm (iOS 26/27).
///
/// Trên iOS 26+ dùng trực tiếp `.glassEffect()` / `.buttonStyle(.glass)` của
/// SwiftUI. Fallback material giữ cho project vẫn biên dịch được với SDK cũ.
struct LiquidGlassModifier: ViewModifier {
    var cornerRadius: CGFloat = 14
    var tint: Color?
    var interactive: Bool = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            let glass: Glass = tint.map { Glass.regular.tint($0) } ?? .regular
            content
                .glassEffect(interactive ? glass.interactive() : glass,
                             in: RoundedRectangle(cornerRadius: cornerRadius,
                                                  style: .continuous))
        } else {
            content
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
                )
                .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 3)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}

extension View {
    /// Áp dụng hiệu ứng kính cho view (card, banner…).
    func liquidGlass(cornerRadius: CGFloat = 14,
                     tint: Color? = nil,
                     interactive: Bool = false) -> some View {
        modifier(LiquidGlassModifier(cornerRadius: cornerRadius,
                                     tint: tint,
                                     interactive: interactive))
    }

    /// Biến thể cho nút bấm: dùng `.buttonStyle(.glass)` chính chủ của iOS 26.
    @ViewBuilder
    func liquidGlassButton(cornerRadius: CGFloat = 12) -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .liquidGlass(cornerRadius: cornerRadius)
                .contentShape(Rectangle())
        }
    }
}
