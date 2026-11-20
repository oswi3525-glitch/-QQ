import UIKit

/// Thanh phím phụ kiểu terminal, gắn vào `inputAccessoryView` của ô nhập liệu.
/// Mỗi nút gửi đúng mã điều khiển (ESC = \x1b, TAB = \t, Ctrl-C = \x03, ...).
/// Danh sách hàng phím lấy từ `AccessoryPreferences` nên người dùng bật/tắt được trong Settings.
final class TerminalAccessoryView: UIInputView {
    /// Được gọi khi bấm phím có payload điều khiển.
    var onKey: ((TerminalKey.Item) -> Void)?
    /// Được gọi khi bấm phím hành động (COPY / PASTE / SELECT ALL / CLEAR).
    var onAction: ((String) -> Void)?

    private let feedback = UIImpactFeedbackGenerator(style: .light)
    private let stack = UIStackView()
    /// Trạng thái CTRL/ALT đang chờ áp dụng cho ký tự kế tiếp.
    private var pendingControl = false
    private var pendingAlt = false

    init() {
        let height: CGFloat = 148
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: height),
                   inputViewStyle: .keyboard)
        allowsSelfSizing = true
        autoresizingMask = [.flexibleWidth]

        // Stack + constraints chỉ được tạo MỘT lần; `reload()` chỉ thay nội dung bên trong.
        stack.axis = .vertical
        stack.spacing = 4
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        buildRows()
        feedback.prepare()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) chưa hỗ trợ") }

    /// `true` khi người dùng đang giữ CTRL (ký tự gõ tiếp theo sẽ thành mã điều khiển).
    var isControlPending: Bool { pendingControl }

    /// `true` khi người dùng đang giữ ALT (ký tự gõ tiếp theo sẽ có tiền tố ESC).
    var isAltPending: Bool { pendingAlt }

    /// Dựng lại các hàng phím (gọi khi người dùng đổi cấu hình trong Settings).
    func reload() {
        buildRows()
        invalidateIntrinsicContentSize()
    }

    // MARK: - Layout

    /// (Re)build các hàng phím bên trong `stack` đã có sẵn.
    private func buildRows() {
        stack.arrangedSubviews.forEach { subview in
            stack.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }

        let rows = AccessoryPreferences.shared.visibleRows
        guard !rows.isEmpty else { return }

        for row in rows {
            let rowStack = UIStackView()
            rowStack.axis = .horizontal
            rowStack.spacing = 4
            rowStack.distribution = .fillEqually

            for item in row {
                rowStack.addArrangedSubview(makeButton(for: item))
            }
            stack.addArrangedSubview(rowStack)
        }
    }

    private func makeButton(for item: TerminalKey.Item) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.title = item.label
        configuration.baseForegroundColor = .label
        configuration.background.backgroundColor = item.isModifier
            ? UIColor.systemOrange.withAlphaComponent(0.18)
            : UIColor.secondarySystemFill
        configuration.background.cornerRadius = 6
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 4, bottom: 6, trailing: 4)
        configuration.attributedTitle = AttributedString(
            item.label,
            attributes: AttributeContainer([.font: UIFont.monospacedSystemFont(ofSize: 12, weight: .semibold)])
        )

        let button = UIButton(configuration: configuration)
        button.accessibilityLabel = item.label
        button.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.feedback.impactOccurred()
            self.handle(item)
        }, for: .touchUpInside)
        return button
    }

    /// Phím bổ trợ đổi trạng thái; phím thường chuyển tiếp cho delegate.
    private func handle(_ item: TerminalKey.Item) {
        if TerminalKey.isActionKey(item) {
            onAction?(item.label)
            return
        }
        switch item.payload {
        case TerminalKey.controlModifier:
            pendingControl.toggle()
            onModifierChanged?()
        case TerminalKey.altModifier:
            pendingAlt.toggle()
            onModifierChanged?()
        default:
            onKey?(item)
        }
    }

    /// Được gọi khi trạng thái CTRL/ALT thay đổi để UI cập nhật nhãn.
    var onModifierChanged: (() -> Void)?

    /// Áp CTRL/ALT đang chờ lên một ký tự người dùng vừa gõ.
    /// - Returns: Chuỗi cần chèn, hoặc `nil` nếu không có modifier nào bật.
    func transform(_ character: Character) -> String? {
        if pendingAlt {
            pendingAlt = false
            onModifierChanged?()
            return TerminalKey.escape + String(character)   // Meta = ESC + ký tự
        }
        if pendingControl {
            pendingControl = false
            onModifierChanged?()
            if let code = TerminalKey.controlCode(for: character) { return code }
            return String(character)
        }
        return nil
    }
}

