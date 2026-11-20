import SwiftUI
import UIKit

/// Mã điều khiển gửi tới terminal khi bấm phím phụ (PRD Module 5).
enum TerminalKey {
    static let escape = "\u{1B}"        // \x1b — ESC
    static let tab = "\t"
    static let carriageReturn = "\r"
    static let backspace = "\u{08}"
    static let ctrlC = "\u{03}"         // ^C — ngắt tiến trình
    static let ctrlD = "\u{04}"         // ^D — EOF
    static let ctrlL = "\u{0C}"         // ^L — clear màn hình
    static let ctrlZ = "\u{1A}"         // ^Z — suspend
    static let arrowUp = "\u{1B}[A"
    static let arrowDown = "\u{1B}[B"
    static let arrowRight = "\u{1B}[C"
    static let arrowLeft = "\u{1B}[D"
    static let home = "\u{1B}[H"
    static let end = "\u{1B}[F"
    static let pageUp = "\u{1B}[5~"
    static let pageDown = "\u{1B}[6~"
    static let deleteForward = "\u{1B}[3~"

    /// Marker cho phím bổ trợ (không gửi payload ngay, chờ ký tự kế tiếp).
    static let controlModifier = "__CTRL__"
    static let altModifier = "__ALT__"

    /// Mô tả một phím trên thanh phụ.
    struct Item: Identifiable {
        let id = UUID()
        let label: String
        let payload: String
        let isModifier: Bool

        init(_ label: String, _ payload: String, isModifier: Bool = false) {
            self.label = label
            self.payload = payload
            self.isModifier = isModifier
        }
    }

    /// 3 hàng phím theo PRD Module 5.
    static let rows: [[Item]] = [
        [
            Item("ESC", escape),
            Item("TAB", tab),
            Item("CTRL", controlModifier, isModifier: true),
            Item("ALT", altModifier, isModifier: true),
            Item("⌃C", ctrlC, isModifier: true),
            Item("⌃D", ctrlD, isModifier: true),
            Item("⌃L", ctrlL, isModifier: true),
            Item("⌃Z", ctrlZ, isModifier: true)
        ],
        [
            Item("←", arrowLeft),
            Item("↑", arrowUp),
            Item("↓", arrowDown),
            Item("→", arrowRight),
            Item("HOME", home),
            Item("END", end),
            Item("PGUP", pageUp),
            Item("PGDN", pageDown)
        ],
        [
            Item("COPY", ""),
            Item("PASTE", ""),
            Item("SELECT ALL", ""),
            Item("CLEAR", "")
        ]
    ]

    /// Các phím thuần hành động (COPY/PASTE/... do UI tự xử lý).
    static func isActionKey(_ item: Item) -> Bool {
        item.payload.isEmpty
    }

    /// Phím bổ trợ (CTRL/ALT): đổi trạng thái chờ, không gửi payload ngay.
    static func isModifierKey(_ item: Item) -> Bool {
        item.payload == controlModifier || item.payload == altModifier
    }

    /// Chuyển một ký tự ASCII thành mã điều khiển tương ứng khi giữ CTRL.
    /// `c` → `\x03`, `a` → `\x01`, `[` → `\x1b`, `?` → `\x7f`.
    static func controlCode(for character: Character) -> String? {
        guard let ascii = character.lowercased().first?.asciiValue else { return nil }
        switch ascii {
        case 0x61...0x7A:                     // a-z → 0x01-0x1A
            return String(UnicodeScalar(ascii - 0x60)!)
        case 0x5B, 0x5C, 0x5D, 0x5E, 0x5F:    // [ \ ] ^ _
            return String(UnicodeScalar(ascii - 0x40)!)
        case 0x3F:                            // ? → DEL
            return String(UnicodeScalar(0x7F)!)
        case 0x40:                            // @ → NUL
            return String(UnicodeScalar(0x00)!)
        default:
            return nil
        }
    }
}
