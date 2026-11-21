import SwiftUI

/// Phong cách "Liquid Glass" dùng chung cho toàn bộ WQTerm.
///
/// Lớp material (ultraThinMaterial) + viền sáng mỏng + bóng mềm tái tạo hiệu ứng
/// kính của iOS 26/27 nhưng vẫn biên dịch được với SDK iOS 17 (CI không đảm bảo
/// luôn có Xcode 27). Tự động thích ứng Dark Mode nhờ hoặc `fill(.ultraThinMaterial)`
/// và `stroke(.white.opacity(...))` — không hard-code màu nền.
struct LiquidGlassModifier: ViewModifier {
    var cornerRadius: CGFloat = 14
    var tint: Color = .white
    var strokeOpacity: CGFloat = 0.18
    var shadowRadius: CGFloat = 8

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(tint.opacity(strokeOpacity), lineWidth: 0.8)
            )
            .shadow(color: .black.opacity(0.12), radius: shadowRadius, x: 0, y: 3)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

extension View {
    /// Áp dụng hiệu ứng kính cho view (nút, card, banner…).
    func liquidGlass(cornerRadius: CGFloat = 14,
                     tint: Color = .white,
                     strokeOpacity: CGFloat = 0.18) -> some View {
        modifier(LiquidGlassModifier(cornerRadius: cornerRadius,
                                     tint: tint,
                                     strokeOpacity: strokeOpacity))
    }

    /// Biến thể cho nút: thêm vùng bấm rõ ràng và trạng thái nhấn.
    func liquidGlassButton(cornerRadius: CGFloat = 12) -> some View {
        self
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .liquidGlass(cornerRadius: cornerRadius)
            .contentShape(Rectangle())
    }
}
