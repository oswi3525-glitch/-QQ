import SwiftUI

/// Hiển thị Markdown nhẹ (heading, list, code block, bold/italic) cho chat AI.
///
/// iOS 15+ có `AttributedString(markdown:)` nhưng không render code block nhiều
/// dòng; ở đây tách khối ``` ra `Text` monospaced để log/config hiển thị đúng.
struct MarkdownTextView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.segments(of: markdown).enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .code(let text):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(text)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .background(Color.secondary.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 8))
                case .prose(let text):
                    Text(Self.attributed(text))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Parsing

    enum Segment {
        case prose(String)
        case code(String)
    }

    /// Tách khối ```…``` khỏi phần văn bản thường.
    static func segments(of text: String) -> [Segment] {
        var result: [Segment] = []
        var buffer: [String] = []
        var inCode = false

        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                if inCode {
                    result.append(.code(buffer.joined(separator: "\n")))
                    buffer.removeAll()
                } else if !buffer.isEmpty {
                    result.append(.prose(buffer.joined(separator: "\n")))
                    buffer.removeAll()
                }
                inCode.toggle()
                continue
            }
            buffer.append(line)
        }

        if !buffer.isEmpty {
            result.append(inCode ? .code(buffer.joined(separator: "\n"))
                                 : .prose(buffer.joined(separator: "\n")))
        }
        return result.isEmpty ? [.prose(text)] : result
    }

    /// Chuyển Markdown inline sang `AttributedString`; fallback về text thô.
    static func attributed(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: text, options: options))
            ?? AttributedString(text)
    }
}
