import Foundation

enum CommandRunner {
    static func runCommand(_ cmd: String) -> (status: Int32, output: String) {
        // TODO: nối ios_system
        return (-1, "unsupported on iOS")
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
