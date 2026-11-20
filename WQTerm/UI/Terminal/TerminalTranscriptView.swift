import SwiftUI
import UIKit

/// Vùng hiển thị transcript (chỉ đọc, chọn/copy được).
/// Không tự nhận focus — bàn phím do `TerminalInputField` sở hữu.
final class TerminalDisplayView: UITextView {
    override var canBecomeFirstResponder: Bool { false }

    func configure() {
        isEditable = false
        isSelectable = true
        isScrollEnabled = true
        backgroundColor = .clear
        textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        autocorrectionType = .no
        autocapitalizationType = .none
        accessibilityLabel = "Nội dung terminal"
    }

    /// Vẽ lại toàn bộ transcript.
    func render(entries: [TerminalEntry]) {
        let mono = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let monoBold = UIFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
        let output = NSMutableAttributedString()

        for entry in entries {
            let color: UIColor
            let font: UIFont
            switch entry.kind {
            case .command:
                color = .systemGreen
                font = monoBold
            case .error:
                color = .systemRed
                font = mono
            case .info:
                color = .secondaryLabel
                font = mono
            case .output:
                color = .label
                font = mono
            }
            output.append(NSAttributedString(string: entry.text + "\n",
                                             attributes: [.font: font, .foregroundColor: color]))
        }

        attributedText = output
        scrollToBottom()
    }

    func scrollToBottom() {
        guard attributedText.length > 0 else { return }
        scrollRangeToVisible(NSRange(location: attributedText.length - 1, length: 1))
    }
}

/// Bọc `TerminalDisplayView` cho SwiftUI.
struct TerminalTranscriptView: UIViewRepresentable {
    @ObservedObject var session: ShellSession

    func makeUIView(context: Context) -> TerminalDisplayView {
        let view = TerminalDisplayView()
        view.configure()
        context.coordinator.render(session.entries, in: view)
        return view
    }

    func updateUIView(_ uiView: TerminalDisplayView, context: Context) {
        context.coordinator.render(session.entries, in: uiView)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var token = ""

        func render(_ entries: [TerminalEntry], in view: TerminalDisplayView) {
            let newToken = "\(entries.count)|\(entries.last?.id.uuidString ?? "")"
            guard newToken != token else { return }
            token = newToken
            view.render(entries: entries)
        }
    }
}
