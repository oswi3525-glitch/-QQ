import SwiftUI
import UIKit

/// Ô nhập lệnh — sở hữu bàn phím hệ thống và `inputAccessoryView`.
///
/// Đây là control duy nhất nhận focus, nên bàn phím luôn bật khi chạm vào terminal
/// và thanh phím phụ luôn hiển thị phía trên.
final class TerminalInputField: UITextField, UITextFieldDelegate {
    var onSubmit: ((String) -> Void)?
    var onHistoryUp: (() -> String?)?
    var onHistoryDown: (() -> String?)?
    var onInterrupt: (() -> Void)?
    var onClearScreen: (() -> Void)?
    var onCopyTranscript: (() -> String)?
    var onControlSequence: ((String) -> Void)?

    private let accessory = TerminalAccessoryView()

    override var canBecomeFirstResponder: Bool { true }

    // MARK: - Setup

    func configure(prompt: String) {
        basePrompt = prompt
        placeholder = prompt
        font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textColor = .label
        backgroundColor = .clear
        borderStyle = .none
        autocorrectionType = .no
        autocapitalizationType = .none
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        keyboardType = .asciiCapable
        keyboardAppearance = .default
        returnKeyType = .go
        enablesReturnKeyAutomatically = false
        delegate = self
        accessibilityLabel = "Nhập lệnh terminal"

        accessory.onKey = { [weak self] item in self?.handle(item) }
        accessory.onAction = { [weak self] action in self?.handleAction(action) }
        accessory.onModifierChanged = { [weak self] in
            guard let self else { return }
            self.updatePromptForModifiers()
            // Reload lại để nhãn CTRL/ALT phản ánh trạng thái đang chờ.
            self.accessory.reload()
        }
        inputAccessoryView = accessory

        // Theo dõi thay đổi focus để SwiftUI biết bàn phím đang mở.
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleTextChange),
            name: UITextField.textDidChangeNotification, object: self
        )
    }

    @objc private func handleTextChange() {
        // Chỉ giữ 1 dòng để prompt không bị vỡ layout.
        if let text, text.contains("\n") {
            self.text = text.replacingOccurrences(of: "\n", with: " ")
        }
    }

    // MARK: - CTRL / ALT modifiers

    /// Áp CTRL/ALT đang chờ lên ký tự người dùng vừa gõ.
    ///
    /// Dùng `shouldChangeCharactersIn` (delegate chính thức của UITextField) thay vì
    /// override `insertText(_:)` — `insertText` là yêu cầu của protocol `UIKeyInput`
    /// nên override không đảm bảo biên dịch được trên mọi SDK.
    ///
    /// - CTRL + `c` ⇒ chèn `\x03` (đúng mã điều khiển, không phải chữ "c")
    /// - ALT + `f` ⇒ chèn `\x1bf` (Meta-key của readline/a-Shell)
    func textField(_ textField: UITextField,
                   shouldChangeCharactersIn range: NSRange,
                   replacementString string: String) -> Bool {
        // Xoá (backspace) hoặc dán nhiều ký tự ⇒ giữ hành vi mặc định.
        guard string.count == 1,
              let character = string.first,
              let transformed = accessory.transform(character) else {
            return true
        }

        let current = textField.text ?? ""
        guard let stringRange = Range(range, in: current) else { return true }
        let updated = current.replacingCharacters(in: stringRange, with: transformed)
        textField.text = updated

        // Đặt lại con trỏ ngay sau phần vừa chèn.
        let offset = range.location + transformed.utf16.count
        if let position = textField.position(from: textField.beginningOfDocument, offset: offset) {
            textField.selectedTextRange = textField.textRange(from: position, to: position)
        }

        onControlSequence?(transformed)
        return false
    }

    /// Cập nhật placeholder để người dùng thấy modifier đang bật.
    private func updatePromptForModifiers() {
        var hints: [String] = []
        if accessory.isControlPending { hints.append("CTRL") }
        if accessory.isAltPending { hints.append("ALT") }
        let suffix = hints.isEmpty ? "" : " [\(hints.joined(separator: "+")) đang bật]"
        placeholder = basePrompt + suffix
    }

    /// Prompt gốc, không kèm trạng thái modifier.
    private var basePrompt: String = ""

    /// Cho phép TerminalView cập nhật prompt khi thư mục làm việc đổi.
    func updatePrompt(_ prompt: String) {
        basePrompt = prompt
        updatePromptForModifiers()
    }

    // MARK: - Submitting

    @discardableResult
    func submitCurrentLine() -> Bool {
        let command = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        text = ""
        guard !command.isEmpty else { return false }
        onSubmit?(command)
        return true
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        submitCurrentLine()
        return true
    }

    // MARK: - Accessory handling

    /// Phím có mã điều khiển (ESC, TAB, Ctrl-*, mũi tên, Home/End...).
    ///
    /// Mọi phím đều **gửi đúng mã điều khiển** tới shell (`\x1b` cho ESC, `\t` cho TAB,
    /// `\x03` cho Ctrl-C…) thay vì chỉ sửa text field, để a-Shell/CLI nhận được phím.
    private func handle(_ item: TerminalKey.Item) {
        switch item.payload {
        case TerminalKey.escape:
            // ESC: gửi \x1b đồng thời xoá dòng đang gõ (hành vi shell chuẩn).
            text = ""
            onControlSequence?(TerminalKey.escape)
        case TerminalKey.arrowUp:
            if let previous = onHistoryUp?() { text = previous }
            onControlSequence?(item.payload)
        case TerminalKey.arrowDown:
            if let next = onHistoryDown?() { text = next }
            onControlSequence?(item.payload)
        case TerminalKey.ctrlC:
            text = ""
            onInterrupt?()
            onControlSequence?(item.payload)
        case TerminalKey.ctrlD:
            // EOF: chỉ gửi mã, không xoá buffer.
            onControlSequence?(item.payload)
        case TerminalKey.ctrlL:
            onClearScreen?()
            onControlSequence?(item.payload)
        case TerminalKey.home, TerminalKey.end:
            // Đưa con trỏ về đầu/cuối dòng đang gõ.
            let position = item.payload == TerminalKey.home ? beginningOfDocument : endOfDocument
            selectedTextRange = textRange(from: position, to: position)
            onControlSequence?(item.payload)
        default:
            // TAB, Ctrl-Z và các ký tự in được: chèn vào dòng lệnh.
            insertControl(item.payload)
        }
    }

    private func insertControl(_ payload: String) {
        let current = text ?? ""
        let selected = selectedTextRange
        if let selected, !selected.isEmpty {
            replace(selected, withText: payload)
        } else {
            text = current + payload
        }
        onControlSequence?(payload)
    }

    /// Phím hành động của thanh phụ (Module 6: "nút Copy/Paste phải hoạt động").
    ///
    /// - COPY: ưu tiên copy **dòng đang gõ**; nếu trống thì copy toàn bộ transcript.
    /// - PASTE: chèn clipboard vào vị trí con trỏ, bỏ ký tự xuống dòng để không phá
    ///   layout một dòng của prompt.
    /// - SELECT ALL / CLEAR: chọn toàn dòng / xoá dòng + màn hình.
    private func handleAction(_ action: String) {
        switch action {
        case "COPY":
            let line = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let payload = line.isEmpty ? (onCopyTranscript?() ?? "") : line
            guard !payload.isEmpty else { return }
            UIPasteboard.general.string = payload
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onControlSequence?("COPY \(payload.count) ký tự")

        case "PASTE":
            guard let pasted = UIPasteboard.general.string, !pasted.isEmpty else { return }
            let sanitized = pasted
                .replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
            if let selected = selectedTextRange, !selected.isEmpty {
                replace(selected, withText: sanitized)
            } else {
                insertText(sanitized)
            }
            onControlSequence?("PASTE \(sanitized.count) ký tự")

        case "SELECT ALL":
            // Chọn toàn bộ dòng lệnh đang gõ.
            selectedTextRange = textRange(from: beginningOfDocument, to: endOfDocument)

        case "CLEAR":
            text = ""
            onClearScreen?()

        default:
            break
        }
    }
}

/// Bọc `TerminalInputField` cho SwiftUI, tự động focus khi xuất hiện.
struct TerminalInputRepresentable: UIViewRepresentable {
    @ObservedObject var session: ShellSession
    @Binding var isFocused: Bool

    func makeUIView(context: Context) -> TerminalInputField {
        let field = TerminalInputField()
        field.configure(prompt: "\(session.promptText) nhập lệnh…")
        field.onSubmit = { command in session.runInBackground(command) }
        field.onHistoryUp = { session.previousCommand() }
        field.onHistoryDown = { session.nextCommand() }
        field.onInterrupt = { session.sendInterrupt() }
        field.onClearScreen = { session.clearHistory() }
        field.onCopyTranscript = { session.transcript }
        field.onControlSequence = { payload in session.handleControlSequence(payload) }
        return field
    }

    func updateUIView(_ uiView: TerminalInputField, context: Context) {
        // Đồng bộ prompt khi thư mục làm việc thay đổi (cd ...).
        uiView.updatePrompt("\(session.promptText) nhập lệnh…")
        if isFocused, !uiView.isFirstResponder {
            uiView.becomeFirstResponder()
        } else if !isFocused, uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {}
}
